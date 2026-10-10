import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/emby/emby_client.dart';
import '../data/media/media_models.dart';

typedef PlaybackInfoResult = ({List<MediaSourceInfo> sources, String? playSessionId});

/// 播放预加载（docs/08-player.md §1.2）：让按下播放到出画面更快。
///
/// 1. 播放信息缓存：详情页 / 首页焦点停留时提前请求 PlaybackInfo，播放页直接用（3 分钟内有效）。
/// 2. 视频预热：提前读取片头、片尾索引区和续播位置附近的少量数据。服务器 / 反向代理 / 网盘直链在第一次访问时
///    往往要唤醒硬盘、解析 302 直链、建立回源连接，预热后播放器打开时这些都已就绪。
class PlaybackPreloader {
  PlaybackPreloader._();

  static const infoTtl = Duration(minutes: 3);
  static const warmTtl = Duration(minutes: 5);

  /// 片头读取量（容器头部 + 第一个关键帧附近）
  static const headBytes = 1024 * 1024;

  /// 片尾读取量（MKV Cues / MP4 moov 可能在文件末尾）
  static const tailBytes = 256 * 1024;

  /// 续播位置附近读取量
  static const resumeBytes = 1024 * 1024;

  static bool enabled = true;

  static final _info = <String, (DateTime, PlaybackInfoResult)>{};
  static final _pending = <String, Future<PlaybackInfoResult>>{};
  static final _warmed = <String, DateTime>{};

  static String _key(String serverId, String itemId) => '$serverId/$itemId';

  /// 记下（别处已经请求到的）播放信息
  static void put(String serverId, String itemId, PlaybackInfoResult info) =>
      _info[_key(serverId, itemId)] = (DateTime.now(), info);

  /// 取预加载好的播放信息（过期返回 null）
  static PlaybackInfoResult? cached(String serverId, String itemId) {
    final hit = _info[_key(serverId, itemId)];
    if (hit == null) return null;
    if (DateTime.now().difference(hit.$1) > infoTtl) {
      _info.remove(_key(serverId, itemId));
      return null;
    }
    return hit.$2;
  }

  /// 获取播放信息：有缓存用缓存，正在预加载就等它，否则现请求
  static Future<PlaybackInfoResult> info(EmbyClient client, String serverId, String itemId) {
    final hit = cached(serverId, itemId);
    if (hit != null) return Future.value(hit);
    final key = _key(serverId, itemId);
    return _pending[key] ??= client
        .playbackInfo(itemId)
        .then((r) {
          put(serverId, itemId, r);
          return r;
        })
        // 注意不能写成 `=> _pending.remove(key)`：remove 返回的正是这个 Future，whenComplete 会等它自己而死锁
        .whenComplete(() {
          _pending.remove(key);
        });
  }

  /// 预加载一个条目：取播放信息并预热默认版本（或 [sourceId] 指定的版本）
  static Future<void> preload(EmbyClient client, MediaItem item, {String? sourceId, Duration? position}) async {
    if (!enabled || !item.playable) return;
    try {
      final info = await PlaybackPreloader.info(client, item.serverId, item.id);
      final source = info.sources.where((s) => s.id == sourceId).firstOrNull ?? info.sources.firstOrNull;
      if (source == null) return;
      await warm(client, source, playSessionId: info.playSessionId, position: position ?? item.position);
    } catch (e) {
      debugPrint('preload ${item.id} failed: $e');
    }
  }

  /// 预热视频流（同一版本 5 分钟内只做一次）
  static Future<void> warm(
    EmbyClient client,
    MediaSourceInfo source, {
    String? playSessionId,
    Duration position = Duration.zero,
  }) async {
    if (!enabled) return;
    final key = '${source.serverId}/${source.itemId}/${source.id}';
    final last = _warmed[key];
    if (last != null && DateTime.now().difference(last) < warmTtl) return;
    _warmed[key] = DateTime.now();

    final req = client.stream(source, playSessionId: playSessionId);
    final size = source.size;
    final ranges = <(int, int)>[(0, headBytes - 1)];
    if (size != null && size > headBytes * 4) {
      ranges.add((size - tailBytes, size - 1));
      final duration = source.duration;
      if (position > const Duration(seconds: 30) && duration != null && duration > Duration.zero) {
        final at = (size * (position.inMilliseconds / duration.inMilliseconds)).floor().clamp(0, size - resumeBytes);
        ranges.add((at, at + resumeBytes - 1));
      }
    }
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20),
        headers: req.headers,
        responseType: ResponseType.stream,
        validateStatus: (s) => s != null && s < 400,
      ),
    );
    try {
      await Future.wait(ranges.map((r) => _read(dio, req.url, r.$1, r.$2)));
    } catch (e) {
      _warmed.remove(key);
      debugPrint('warm ${source.itemId} failed: $e');
    } finally {
      dio.close(force: true);
    }
  }

  /// 读一段数据后丢弃（服务器不支持 Range 时最多读 [end - start + 1] 字节就断开）
  static Future<void> _read(Dio dio, Uri url, int start, int end) async {
    final limit = end - start + 1;
    final r = await dio.getUri<ResponseBody>(url, options: Options(headers: {'Range': 'bytes=$start-$end'}));
    var got = 0;
    final done = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    sub = r.data!.stream.listen(
      (chunk) {
        got += chunk.length;
        if (got >= limit && !done.isCompleted) {
          done.complete();
          sub.cancel();
        }
      },
      onDone: () => done.isCompleted ? null : done.complete(),
      onError: (Object e) => done.isCompleted ? null : done.completeError(e),
      cancelOnError: true,
    );
    await done.future;
  }

  @visibleForTesting
  static void reset() {
    _info.clear();
    _pending.clear();
    _warmed.clear();
  }
}
