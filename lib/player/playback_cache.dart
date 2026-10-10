import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'preload.dart';

/// 播放缓存：mpv 的磁盘缓冲文件（缓冲上限超过内存上限时使用）与预加载的数据。
class PlaybackCache {
  PlaybackCache._();

  /// 缓冲上限超过这个值时，mpv 改用磁盘缓存（避免占用大量内存）
  static const memoryLimitBytes = 256 * 1024 * 1024;

  static Directory? _dir;

  /// 磁盘缓存目录（系统临时目录下的 viora_play_cache）
  static Future<String?> dir() async {
    if (kIsWeb) return null;
    try {
      final d = _dir ??= Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}viora_play_cache');
      if (!d.existsSync()) d.createSync(recursive: true);
      return d.path;
    } catch (_) {
      return null;
    }
  }

  /// 磁盘缓存占用（字节）
  static Future<int> size() async {
    final path = await dir();
    if (path == null) return 0;
    var total = 0;
    try {
      await for (final f in Directory(path).list(recursive: true, followLinks: false)) {
        if (f is File) total += await f.length();
      }
    } catch (_) {}
    return total;
  }

  /// 清除全部播放缓存：磁盘缓冲文件、预加载的播放信息与预热记录。
  /// [keepPreload]：直接切到下一集 / 其他版本时保留刚预加载好的数据
  static Future<void> clear({bool keepPreload = false}) async {
    if (!keepPreload) PlaybackPreloader.reset();
    final path = await dir();
    if (path == null) return;
    try {
      await for (final f in Directory(path).list(followLinks: false)) {
        try {
          await f.delete(recursive: true);
        } catch (_) {
          // 正在被播放器占用的文件删不掉，下次再清
        }
      }
    } catch (_) {}
  }
}
