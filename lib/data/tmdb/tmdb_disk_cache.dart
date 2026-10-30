import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// TMDB 接口响应的磁盘缓存：每条一个文件，总量超过上限时删掉最久没写过的。
///
/// 以前存在 SharedPreferences 里且从不清理：那是一个整体读写的文件，用久了会有好几 MB，
/// 启动时要整个读进来解析，Windows 上每写一条还要把整个文件重新编码写一遍（都在界面线程），首页加载时会卡。
abstract final class TmdbDiskCache {
  static const maxBytes = 40 << 20;
  static const _legacyPrefix = 'flutter.viora.tmdb.';

  static Future<Directory?>? _dir;

  static Future<Directory?> _directory() => _dir ??= () async {
    if (kIsWeb) return null;
    try {
      final d = Directory('${(await getApplicationSupportDirectory()).path}/tmdb_cache');
      await d.create(recursive: true);
      return d;
    } catch (_) {
      return null;
    }
  }();

  static String _file(Directory d, String key) => '${d.path}/${sha1.convert(utf8.encode(key))}.json';

  static Future<String?> read(String key) async {
    try {
      final d = await _directory();
      if (d == null) return null;
      final f = File(_file(d, key));
      return await f.exists() ? await f.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String key, String value) async {
    try {
      final d = await _directory();
      if (d == null) return;
      final path = _file(d, key);
      final tmp = File('$path.tmp');
      await tmp.writeAsString(value, flush: true);
      await tmp.rename(path);
    } catch (e) {
      debugPrint('tmdb cache write failed: $e');
    }
  }

  /// 超过上限时按修改时间从旧到新删到 80%；启动后在后台调用
  static Future<void> prune() async {
    final d = await _directory();
    if (d == null) return;
    try {
      final files = <(File, int, DateTime)>[];
      var total = 0;
      await for (final f in d.list(followLinks: false)) {
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

  /// 一次性清掉旧版本存在 SharedPreferences 里的 TMDB 缓存（一个操作按前缀删除，不逐条重写文件）
  static Future<void> dropLegacyPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!prefs.getKeys().any((k) => k.startsWith('viora.tmdb.'))) return;
      await SharedPreferencesStorePlatform.instance.clearWithParameters(
        ClearParameters(filter: PreferencesFilter(prefix: _legacyPrefix)),
      );
      await prefs.reload();
    } catch (e) {
      debugPrint('drop legacy tmdb cache failed: $e');
    }
  }

  @visibleForTesting
  static set directoryForTest(Directory? d) => _dir = Future.value(d);
}
