import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/net/image_request_pool.dart';
import '../../app/tv_performance.dart';

/// 带磁盘缓存的网络图片（海报、背景图等）。
///
/// 媒体服务器的图片地址里带图片版本 tag，TMDB 图片地址不变，所以按地址缓存即可。
/// 再次打开应用时直接读本地文件，不再向 NAS 请求（也省去 Emby 现场缩放图片的 CPU）。
/// 缓存上限 [maxBytes]，超出时启动后按最久未使用清理。
class CachedNetImage extends ImageProvider<CachedNetImage> {
  const CachedNetImage(this.url, {this.headers = const {}, this.priority = ImageRequestPriority.normal});

  final String url;
  final Map<String, String> headers;
  final ImageRequestPriority priority;

  static const maxBytes = 512 * 1024 * 1024;
  static Future<Directory?>? _dir;
  static final _inflight = <String, Future<Uint8List>>{};
  static final _priorities = <String, ImageRequestPriority>{};
  static ImageRequestPool _pool = ImageRequestPool(6);
  static HttpClient? _client;
  static Duration _requestTimeout = const Duration(seconds: 45);
  static int _baselineDownloads = 0;
  static int get activeDownloads => _pool.active + _baselineDownloads;
  static int get queuedDownloads => _pool.queued;

  static void configure({required bool tv}) {
    if (_pool.active == 0 && _pool.queued == 0) _pool = ImageRequestPool(tv ? 4 : 6);
  }

  static HttpClient get _http => _client ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = 4;

  @visibleForTesting
  static void resetNetworkForTesting({Duration timeout = const Duration(seconds: 45)}) {
    assert(_pool.active == 0 && _pool.queued == 0);
    _client?.close(force: true);
    _client = null;
    _requestTimeout = timeout;
    _inflight.clear();
    _priorities.clear();
  }

  // Headers are part of cache identity; priority is not, so prefetch is reusable.
  String get _identity => headers.isEmpty
      ? url
      : jsonEncode([
          url,
          {for (final k in headers.keys.toList()..sort()) k: headers[k]},
        ]);

  static Future<Directory?> _cacheDir() => _dir ??= () async {
    if (kIsWeb) return null;
    try {
      final d = Directory('${(await getApplicationCacheDirectory()).path}${Platform.pathSeparator}viora_images');
      if (!d.existsSync()) d.createSync(recursive: true);
      return d;
    } catch (_) {
      return null;
    }
  }();

  static String _name(String url) => sha1.convert(utf8.encode(url)).toString();

  @override
  Future<CachedNetImage> obtainKey(ImageConfiguration configuration) {
    // Runs even when ImageCache already holds the same pending prefetch.
    final key = _identity;
    if (_inflight.containsKey(key)) {
      final previous = _priorities[key];
      if (previous == null || priority.index < previous.index) _priorities[key] = priority;
      _pool.promote(key, priority);
    }
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(CachedNetImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1, debugLabel: url);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    // 注意不能写成 `whenComplete(() => _inflight.remove(url))`：remove 返回的正是这个 Future，会自己等自己而永远不完成
    final key = _identity;
    final previous = _priorities[key];
    if (previous == null || priority.index < previous.index) _priorities[key] = priority;
    _pool.promote(key, priority);
    final bytes = await (_inflight[key] ??= _bytes().whenComplete(() {
      _inflight.remove(key);
      _priorities.remove(key);
    }));
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  Future<Uint8List> _bytes() async {
    final dir = await _cacheDir();
    final file = dir == null ? null : File('${dir.path}${Platform.pathSeparator}${_name(_identity)}');
    if (file != null && await file.exists()) {
      try {
        final data = await file.readAsBytes();
        if (data.isNotEmpty) {
          // 更新访问时间，清理时保留常用的
          unawaited(file.setLastModified(DateTime.now()).catchError((_) {}));
          return data;
        }
      } catch (_) {}
    }
    final data = TvPerformance.baseline
        ? await _baselineDownload()
        : await _pool.run(_identity, _download, priority: _priorities[_identity] ?? priority);
    if (file != null) {
      unawaited(file.writeAsBytes(data, flush: false).then((_) {}, onError: (_) {}));
    }
    return data;
  }

  Future<Uint8List> _baselineDownload() async {
    _baselineDownloads++;
    try {
      return await _download(shared: false);
    } finally {
      _baselineDownloads--;
    }
  }

  Future<Uint8List> _download({bool shared = true}) async {
    final client = shared ? _http : (HttpClient()..connectionTimeout = const Duration(seconds: 15));
    HttpClientRequest? request;
    StreamSubscription<List<int>>? body;
    var expired = false;
    try {
      return await (() async {
        final req = request = await client.getUrl(Uri.parse(url));
        if (expired) {
          req.abort();
          throw TimeoutException('Image request expired');
        }
        headers.forEach(req.headers.set);
        final res = await req.close();
        if (res.statusCode != HttpStatus.ok) {
          await res.listen((_) {}).cancel();
          throw HttpException('HTTP ${res.statusCode}');
        }
        final data = BytesBuilder(copy: false);
        final done = Completer<Uint8List>();
        body = res.listen(
          data.add,
          onDone: () => done.complete(data.takeBytes()),
          onError: (Object e, StackTrace s) => done.completeError(e, s),
          cancelOnError: true,
        );
        final bytes = await done.future;
        if (bytes.isEmpty) throw const HttpException('empty image');
        return bytes;
      })().timeout(_requestTimeout);
    } catch (_) {
      expired = true;
      request?.abort();
      await body?.cancel();
      rethrow;
    } finally {
      if (!shared) client.close();
    }
  }

  /// 启动时清理：超过上限按最久未使用删除
  static Future<void> prune() async {
    final dir = await _cacheDir();
    if (dir == null) return;
    try {
      final files = <(File, int, DateTime)>[];
      var total = 0;
      await for (final f in dir.list(followLinks: false)) {
        if (f is! File) continue;
        final st = await f.stat();
        files.add((f, st.size, st.modified));
        total += st.size;
      }
      if (total <= maxBytes) return;
      files.sort((a, b) => a.$3.compareTo(b.$3));
      for (final (f, size, _) in files) {
        if (total <= maxBytes * 0.8) break;
        try {
          await f.delete();
          total -= size;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 图片缓存占用（字节）
  static Future<int> size() async {
    final dir = await _cacheDir();
    if (dir == null) return 0;
    var total = 0;
    try {
      await for (final f in dir.list(followLinks: false)) {
        if (f is File) total += await f.length();
      }
    } catch (_) {}
    return total;
  }

  /// 清除图片缓存
  static Future<void> clear() async {
    final dir = await _cacheDir();
    if (dir == null) return;
    try {
      await for (final f in dir.list(followLinks: false)) {
        try {
          await f.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  @override
  bool operator ==(Object other) => other is CachedNetImage && other._identity == _identity;

  @override
  int get hashCode => _identity.hashCode;

  @override
  String toString() => 'CachedNetImage($url)';
}

/// 网页预览没有本地文件系统：直接用普通网络图片
ImageProvider netImage(
  String url, {
  Map<String, String> headers = const {},
  int? cacheWidth,
  ImageRequestPriority priority = ImageRequestPriority.normal,
}) {
  final ImageProvider base = kIsWeb
      ? NetworkImage(url, headers: headers)
      : CachedNetImage(url, headers: headers, priority: priority);
  return ResizeImage.resizeIfNeeded(cacheWidth, null, base);
}
