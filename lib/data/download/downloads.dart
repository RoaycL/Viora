import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../cache/account_scope.dart';
import '../emby/emby_client.dart';
import '../media/media_models.dart';

/// 下载状态
enum DownloadState { queued, downloading, paused, done, failed }

/// 一个下载（一部电影 / 一集的一个版本）。条目和版本信息存一份，离线时播放页不用再问服务器
class DownloadEntry {
  DownloadEntry({
    required this.serverId,
    required this.account,
    required this.item,
    required this.source,
    required this.path,
    this.state = DownloadState.queued,
    this.received = 0,
    this.total,
    this.error,
    this.position = Duration.zero,
    this.played = false,
    this.progressAt,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  final String serverId;

  /// 账号（[accountScope]）：换了账号的同一台服务器不共用
  final String account;
  final MediaItem item;
  final MediaSourceInfo source;

  /// 下载完成后的文件；下载中写到 `$path.part`
  final String path;
  final DateTime addedAt;
  DownloadState state;
  int received;
  int? total;
  String? error;

  /// 离线时在本机看到的位置（联网后由「补发上报」同步给服务器，见 PendingPlayReports）
  Duration position;
  bool played;
  DateTime? progressAt;

  String get id => '$account/${item.id}/${source.id}';
  String get partPath => '$path.part';
  String get itemId => item.id;

  double? get fraction {
    final t = total;
    if (t == null || t <= 0) return null;
    return (received / t).clamp(0.0, 1.0);
  }

  Map<String, Object?> toJson() => {
    'server': serverId,
    'account': account,
    'item': item.toCacheJson(),
    'source': sourceToJson(source),
    'path': path,
    'state': (state == DownloadState.downloading || state == DownloadState.queued ? DownloadState.paused : state).name,
    'received': received,
    'total': total,
    'error': error,
    'pos': position.inMilliseconds,
    'played': played,
    'progressAt': progressAt?.millisecondsSinceEpoch,
    'added': addedAt.millisecondsSinceEpoch,
  };

  static DownloadEntry fromJson(Map<String, Object?> j) => DownloadEntry(
    serverId: j['server'] as String,
    account: j['account'] as String,
    item: MediaItem.fromCacheJson((j['item'] as Map).cast<String, Object?>()),
    source: sourceFromJson((j['source'] as Map).cast<String, Object?>()),
    path: j['path'] as String,
    state: DownloadState.values.asNameMap()[j['state']] ?? DownloadState.paused,
    received: (j['received'] as num?)?.toInt() ?? 0,
    total: (j['total'] as num?)?.toInt(),
    error: j['error'] as String?,
    position: Duration(milliseconds: (j['pos'] as num?)?.toInt() ?? 0),
    played: j['played'] as bool? ?? false,
    progressAt: j['progressAt'] == null ? null : DateTime.fromMillisecondsSinceEpoch((j['progressAt'] as num).toInt()),
    addedAt: j['added'] == null ? null : DateTime.fromMillisecondsSinceEpoch((j['added'] as num).toInt()),
  );
}

/// 版本信息只存播放页用得到的字段（音轨 / 字幕选择、媒体信息、HDR 判断）
@visibleForTesting
Map<String, Object?> sourceToJson(MediaSourceInfo s) => {
  'server': s.serverId,
  'item': s.itemId,
  'id': s.id,
  'container': s.container,
  'name': s.name,
  'size': s.size,
  'bitrate': s.bitrate,
  'duration': s.duration?.inMilliseconds,
  'streams': [
    for (final t in s.streams)
      if (!t.isExternal)
        {
          'index': t.index,
          'type': t.type,
          'codec': t.codec,
          'language': t.language,
          'title': t.title,
          'default': t.isDefault,
          'channels': t.channels,
          'width': t.width,
          'height': t.height,
          'bitDepth': t.bitDepth,
          'frameRate': t.frameRate,
          'range': t.range.name,
        },
  ],
};

@visibleForTesting
MediaSourceInfo sourceFromJson(Map<String, Object?> j) => MediaSourceInfo(
  serverId: j['server'] as String,
  itemId: j['item'] as String,
  id: j['id'] as String,
  container: j['container'] as String? ?? '',
  name: j['name'] as String?,
  size: (j['size'] as num?)?.toInt(),
  bitrate: (j['bitrate'] as num?)?.toInt(),
  duration: j['duration'] == null ? null : Duration(milliseconds: (j['duration'] as num).toInt()),
  streams: [
    for (final t in (j['streams'] as List? ?? const []).cast<Map<dynamic, dynamic>>())
      MediaStreamInfo(
        index: (t['index'] as num).toInt(),
        type: t['type'] as String,
        codec: t['codec'] as String?,
        language: t['language'] as String?,
        title: t['title'] as String?,
        isDefault: t['default'] as bool? ?? false,
        channels: (t['channels'] as num?)?.toInt(),
        width: (t['width'] as num?)?.toInt(),
        height: (t['height'] as num?)?.toInt(),
        bitDepth: (t['bitDepth'] as num?)?.toInt(),
        frameRate: (t['frameRate'] as num?)?.toDouble(),
        range: VideoRange.values.asNameMap()[t['range']] ?? VideoRange.sdr,
      ),
  ],
);

/// 离线下载（docs/08-player.md「离线下载」）：下载服务器上的原始文件（Static 直接播放地址，不转码），
/// 一次下载一个，支持暂停和断点续传（HTTP Range）。下载列表存在应用数据目录的 downloads.json。
///
/// 播放页打开已下载完的条目时直接播本地文件（[playable]），不请求播放信息，没有网络也能看；
/// 离线看的进度先记在这里，停止上报会存进待补发列表，联网后自动同步给服务器。
class Downloads extends ChangeNotifier {
  Downloads._();

  static final instance = Downloads._();

  final List<DownloadEntry> _entries = [];
  List<DownloadEntry> get entries => List.unmodifiable(_entries);

  Future<void>? _loading;
  String? _indexPath;
  String? _dir;
  DownloadEntry? _active;
  CancelToken? _cancel;
  Timer? _saveTimer;
  Future<void>? _running;
  Future<void> _saving = Future.value();

  /// 测试用：等当前这个下载任务收尾（文件写完、关掉）
  @visibleForTesting
  Future<void> get debugIdle async {
    while (_running != null) {
      await _running;
    }
  }

  /// 测试用：指定存放目录（索引和文件都放在这里）
  @visibleForTesting
  static String? debugDir;

  @visibleForTesting
  void debugReset() {
    _cancel?.cancel();
    _saveTimer?.cancel();
    _entries.clear();
    _loading = null;
    _loaded = false;
    _active = null;
    _indexPath = null;
    _dir = null;
  }

  /// 读取下载列表（只读一次；启动时就开始读）
  Future<void> load() => _loading ??= _load();

  /// 下载列表读完了没有（播放页不等它：没读完就当没有下载）
  bool get loaded => _loaded;
  bool _loaded = false;

  Future<void> _load() async {
    try {
      final support = debugDir ?? (await getApplicationSupportDirectory()).path;
      _indexPath = '$support${Platform.pathSeparator}downloads.json';
      _dir = await _downloadDir();
      final f = File(_indexPath!);
      if (await f.exists()) {
        final list = jsonDecode(await f.readAsString()) as List;
        for (final j in list) {
          try {
            final e = DownloadEntry.fromJson((j as Map).cast<String, Object?>());
            // 文件被删掉了：下载完的去掉，没下完的从头再来
            if (e.state == DownloadState.done && !File(e.path).existsSync()) continue;
            if (e.state != DownloadState.done) {
              final part = File(e.partPath);
              e.received = part.existsSync() ? part.lengthSync() : 0;
            }
            _entries.add(e);
          } catch (err) {
            debugPrint('downloads: skip $err');
          }
        }
      }
    } catch (e) {
      debugPrint('downloads: load $e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// 文件放哪：Windows「下载」文件夹下的 Viora；安卓应用专属的外部存储（不用存储权限，卸载时一起删）
  Future<String> _downloadDir() async {
    String base;
    if (debugDir != null) {
      base = debugDir!;
    } else if (Platform.isWindows) {
      base = (await getDownloadsDirectory())?.path ?? (await getApplicationSupportDirectory()).path;
      base = '$base${Platform.pathSeparator}Viora';
    } else if (Platform.isAndroid) {
      base = (await getExternalStorageDirectory())?.path ?? (await getApplicationSupportDirectory()).path;
      base = '$base${Platform.pathSeparator}downloads';
    } else {
      base = '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}downloads';
    }
    await Directory(base).create(recursive: true);
    return base;
  }

  /// 这一集 / 这部电影已下载完的文件；[sourceId] 不为空时只要这个版本。
  /// [account] 是当前登录的账号（`accountScope`）：同一服务器换了账号，不用上一个账号下载的文件和进度
  DownloadEntry? playable(String serverId, String itemId, {required String account, String? sourceId}) {
    for (final e in _entries) {
      if (e.serverId != serverId || e.itemId != itemId || e.state != DownloadState.done) continue;
      if (e.account != account) continue;
      if (sourceId != null && e.source.id != sourceId) continue;
      // 文件在应用开着时被删掉 / 挪走了：不当成已下载（照常在线播）
      if (!File(e.path).existsSync()) continue;
      return e;
    }
    return null;
  }

  /// 这一集 / 这部电影的下载（任意状态，优先 [sourceId] 这个版本）
  DownloadEntry? find(String serverId, String itemId, {required String account, String? sourceId}) {
    final all = _entries.where((e) => e.serverId == serverId && e.itemId == itemId && e.account == account).toList();
    return all.where((e) => e.source.id == sourceId).firstOrNull ?? all.firstOrNull;
  }

  /// 加入下载并开始（已经在列表里时继续下载）
  Future<DownloadEntry> add(EmbyClient client, MediaItem item, MediaSourceInfo source) async {
    await load();
    final account = accountScope(client.server);
    final existing = _entries.where((e) => e.id == '$account/${item.id}/${source.id}').firstOrNull;
    if (existing != null) {
      if (existing.state != DownloadState.done) resume(existing, client);
      return existing;
    }
    final e = DownloadEntry(
      serverId: item.serverId,
      account: account,
      item: item,
      source: source,
      path: _uniquePath(fileNameFor(item, source)),
      total: source.size,
    );
    _entries.add(e);
    _clients[e.id] = client;
    await _save();
    notifyListeners();
    _pump();
    return e;
  }

  final _clients = <String, EmbyClient>{};

  /// 下载时每收到这么多就等一次写盘
  static const _flushEvery = 4 << 20;

  /// 文件路径不和别的下载重复（同一部的不同版本、不同账号下的同一部）：重名时加「 (2)」「 (3)」…
  String _uniquePath(String name) {
    final dot = name.lastIndexOf('.');
    final (base, ext) = dot > 0 ? (name.substring(0, dot), name.substring(dot)) : (name, '');
    final used = {for (final e in _entries) e.path.toLowerCase()};
    for (var n = 1; ; n++) {
      final path = '${_dir!}${Platform.pathSeparator}$base${n == 1 ? '' : ' ($n)'}$ext';
      if (used.contains(path.toLowerCase())) continue;
      if (File(path).existsSync() || File('$path.part').existsSync()) continue;
      return path;
    }
  }

  void pause(DownloadEntry e) {
    if (e.state == DownloadState.done) return;
    e.state = DownloadState.paused;
    if (identical(_active, e)) _cancel?.cancel();
    unawaited(_save());
    notifyListeners();
  }

  void resume(DownloadEntry e, EmbyClient client) {
    if (e.state == DownloadState.done || e.state == DownloadState.downloading) return;
    _clients[e.id] = client;
    e.state = DownloadState.queued;
    e.error = null;
    notifyListeners();
    _pump();
  }

  /// 删除下载（连同文件）
  Future<void> remove(DownloadEntry e) async {
    if (identical(_active, e)) _cancel?.cancel();
    _entries.remove(e);
    _clients.remove(e.id);
    for (final p in [e.path, e.partPath]) {
      try {
        final f = File(p);
        if (await f.exists()) await f.delete();
      } catch (err) {
        debugPrint('downloads: delete $err');
      }
    }
    await _save();
    notifyListeners();
  }

  /// 播放页停止时记下本机的进度（下载页「继续播放」用）
  void recordProgress(
    String serverId,
    String itemId,
    Duration position, {
    required String account,
    required bool played,
  }) {
    var changed = false;
    for (final e in _entries) {
      if (e.serverId == serverId && e.itemId == itemId && e.account == account && e.state == DownloadState.done) {
        e.position = played ? Duration.zero : position;
        e.played = played;
        e.progressAt = DateTime.now();
        changed = true;
      }
    }
    if (changed) {
      unawaited(_save());
      notifyListeners();
    }
  }

  void _pump() {
    if (_active != null) return;
    final next = _entries.where((e) => e.state == DownloadState.queued).firstOrNull;
    if (next == null) return;
    final client = _clients[next.id];
    if (client == null) {
      next.state = DownloadState.paused;
      notifyListeners();
      return;
    }
    _active = next;
    final running = _running = _run(next, client).whenComplete(() {
      _active = null;
      _running = null;
      _pump();
    });
    unawaited(running);
  }

  Future<void> _run(DownloadEntry e, EmbyClient client) async {
    e.state = DownloadState.downloading;
    notifyListeners();
    final cancel = _cancel = CancelToken();
    final part = File(e.partPath);
    Dio? dio;
    IOSink? sink;
    // 读已下载的部分、取播放地址也放进 try：存储读失败时要标成失败，不然一直停在「下载中」，点继续也没反应
    try {
      var start = await part.exists() ? await part.length() : 0;
      final req = client.stream(e.source);
      final http = dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
          headers: req.headers,
          responseType: ResponseType.stream,
          validateStatus: (s) => s != null && (s < 400 || s == 416),
        ),
      );
      Future<Response<ResponseBody>> get(int from) => http.getUri<ResponseBody>(
        req.url,
        options: Options(headers: {if (from > 0) 'Range': 'bytes=$from-'}),
        cancelToken: cancel,
      );
      var resp = await get(start);
      // 416：续传的起点已经在文件末尾（上次写完了还没来得及改名），或者 .part 和服务器上的文件对不上
      var complete = false;
      if (resp.statusCode == 416) {
        resp.data?.stream.listen(null).cancel().ignore();
        final range = resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
        final full = int.tryParse(RegExp(r'/(\d+)').firstMatch(range)?.group(1) ?? '') ?? e.total;
        if (start > 0 && full != null && start == full) {
          complete = true;
        } else {
          // 对不上：丢掉 .part 从头下
          start = 0;
          resp = await get(0);
          if (resp.statusCode == 416) throw const HttpException('服务器拒绝了下载请求（416）');
        }
      }
      if (complete) {
        await _finish(e, part, start);
      } else {
        // 服务器不支持断点续传（返回 200 而不是 206）：从头下载
        if (start > 0 && resp.statusCode != 206) start = 0;
        final length = int.tryParse(resp.headers.value(HttpHeaders.contentLengthHeader) ?? '');
        if (length != null) e.total = start + length;
        e.received = start;
        sink = part.openWrite(mode: start > 0 ? FileMode.append : FileMode.write);
        var lastNotify = DateTime.now();
        var pending = 0;
        await for (final chunk in resp.data!.stream) {
          sink.add(chunk);
          e.received += chunk.length;
          // 写盘比网速慢时不能一直往内存里攒：每攒够一段等它写完再继续收
          pending += chunk.length;
          if (pending >= _flushEvery) {
            pending = 0;
            await sink.flush();
          }
          final now = DateTime.now();
          if (now.difference(lastNotify) > const Duration(milliseconds: 500)) {
            lastNotify = now;
            notifyListeners();
            _saveSoon();
          }
        }
        await sink.flush();
        await sink.close();
        sink = null;
        if (e.total != null && e.received < e.total!) throw const HttpException('连接中断，下载不完整');
        await _finish(e, part, e.received);
      }
    } catch (err) {
      // 写盘失败（比如磁盘满了）时关闭也可能出错：不能让它盖过原来的错误、跳过下面的状态更新
      try {
        await sink?.close();
      } catch (_) {}
      if (e.state == DownloadState.downloading) {
        if (cancel.isCancelled) {
          e.state = DownloadState.paused;
        } else {
          e.state = DownloadState.failed;
          e.error = err is DioException ? (err.message ?? err.type.name) : '$err';
          debugPrint('downloads: ${e.item.name} $err');
        }
      }
    } finally {
      dio?.close(force: true);
      if (identical(_cancel, cancel)) _cancel = null;
    }
    await _save();
    notifyListeners();
  }

  /// 下载完：.part 改成正式文件名
  Future<void> _finish(DownloadEntry e, File part, int size) async {
    final target = File(e.path);
    if (await target.exists()) await target.delete();
    await part.rename(e.path);
    e.received = size;
    e.total = size;
    e.state = DownloadState.done;
    _clients.remove(e.id);
  }

  void _saveSoon() {
    if (_saveTimer?.isActive ?? false) return;
    _saveTimer = Timer(const Duration(seconds: 5), _save);
  }

  /// 写索引：一次只写一个，免得两次写同一个临时文件撞车
  Future<void> _save() => _saving = _saving.then((_) => _write());

  Future<void> _write() async {
    final path = _indexPath;
    if (path == null) return;
    try {
      final tmp = File('$path.tmp');
      await tmp.writeAsString(jsonEncode([for (final e in _entries) e.toJson()]));
      await tmp.rename(path);
    } catch (e) {
      debugPrint('downloads: save $e');
    }
  }
}

/// 下载文件名：「剧名 S01E02 标题 [条目 ID].扩展名」，去掉文件名里不能用的字符
@visibleForTesting
String fileNameFor(MediaItem item, MediaSourceInfo source) {
  final ext = source.container.split(',').first.trim();
  final name = [
    if (item.kind == MediaKind.episode && item.seriesName != null) item.seriesName!,
    if (item.kind == MediaKind.episode) ?item.episodeLabel,
    item.name,
  ].join(' ');
  final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final short = safe.length > 80 ? safe.substring(0, 80).trim() : safe;
  return '$short [${item.id}].${ext.isEmpty ? 'mkv' : ext}';
}
