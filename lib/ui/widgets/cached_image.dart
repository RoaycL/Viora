import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

/// 带磁盘缓存的网络图片（海报、背景图等）。
///
/// 媒体服务器的图片地址里带图片版本 tag，TMDB 图片地址不变，所以按地址缓存即可。
/// 再次打开应用时直接读本地文件，不再向 NAS 请求（也省去 Emby 现场缩放图片的 CPU）。
/// 缓存上限 [maxBytes]，超出时启动后按最久未使用清理。
class CachedNetImage extends ImageProvider<CachedNetImage> {
  const CachedNetImage(this.url, {this.headers = const {}});

  final String url;
  final Map<String, String> headers;

  static const maxBytes = 512 * 1024 * 1024;
  static Future<Directory?>? _dir;
  static final _inflight = <String, Future<Uint8List>>{};

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
  Future<CachedNetImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(CachedNetImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1, debugLabel: url);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await (_inflight[url] ??= _bytes().whenComplete(() => _inflight.remove(url)));
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  Future<Uint8List> _bytes() async {
    final dir = await _cacheDir();
    final file = dir == null ? null : File('${dir.path}${Platform.pathSeparator}${_name(url)}');
    if (file != null && file.existsSync()) {
      try {
        final data = await file.readAsBytes();
        if (data.isNotEmpty) {
          // 更新访问时间，清理时保留常用的
          unawaited(file.setLastModified(DateTime.now()).catchError((_) {}));
          return data;
        }
      } catch (_) {}
    }
    final data = await _download();
    if (file != null) {
      unawaited(file.writeAsBytes(data, flush: false).then((_) {}, onError: (_) {}));
    }
    return data;
  }

  Future<Uint8List> _download() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      headers.forEach(req.headers.set);
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != HttpStatus.ok) throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
      final bytes = await consolidateHttpClientResponseBytes(res).timeout(const Duration(seconds: 60));
      if (bytes.isEmpty) throw const HttpException('empty image');
      return bytes;
    } finally {
      client.close();
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
  bool operator ==(Object other) => other is CachedNetImage && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'CachedNetImage($url)';
}

/// 网页预览没有本地文件系统：直接用普通网络图片
ImageProvider netImage(String url, {Map<String, String> headers = const {}, int? cacheWidth}) {
  final ImageProvider base = kIsWeb ? NetworkImage(url, headers: headers) : CachedNetImage(url, headers: headers);
  return ResizeImage.resizeIfNeeded(cacheWidth, null, base);
}
