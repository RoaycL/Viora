import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// 页面数据快照（继续观看、收藏、观看记录…）：每次从服务器拉到新数据就存一份到磁盘。
/// 下次打开应用时先显示上次的快照（秒开），同时在后台重新拉取，拉到后再替换。
abstract final class SnapshotCache {
  static Future<Directory?>? _dir;

  /// 这次运行里已经用过快照的键：只有启动后第一次加载用快照，之后（如播放完刷新）都直接拉最新
  static final _used = <String>{};

  static Future<Directory?> _directory() => _dir ??= () async {
    if (kIsWeb) return null;
    try {
      final d = Directory('${(await getApplicationSupportDirectory()).path}/snapshots');
      await d.create(recursive: true);
      return d;
    } catch (_) {
      return null;
    }
  }();

  static Future<Object?> read(String key) async {
    try {
      final f = File('${(await _directory())!.path}/$key.json');
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String key, Object? json) async {
    try {
      final d = await _directory();
      if (d == null) return;
      final tmp = File('${d.path}/$key.json.tmp');
      await tmp.writeAsString(jsonEncode(json), flush: true);
      await tmp.rename('${d.path}/$key.json');
    } catch (e) {
      debugPrint('snapshot $key write failed: $e');
    }
  }

  /// 删除所有快照（如退出登录、清除缓存）
  static Future<void> clear() async {
    try {
      final d = await _directory();
      if (d != null && await d.exists()) await d.delete(recursive: true);
      _dir = null;
    } catch (_) {}
  }

  @visibleForTesting
  static void resetForTest() {
    _used.clear();
    _pending.clear();
    _dir = null;
  }

  @visibleForTesting
  static set directoryForTest(Directory d) => _dir = Future.value(d);
}

/// 后台正在拉取的最新数据（键 → 结果），由下一次 build 取走
final _pending = <String, Future<Object?>>{};

/// 先用快照、后台刷新：启动后第一次加载时，有快照就立刻返回快照，同时在后台拉最新数据，
/// 拉到后让 provider 重新加载一次、直接取走拉到的结果（重新加载期间页面继续显示快照，不会闪成加载中）。
/// 没有快照或之后的加载直接 [fetch]，成功后存快照。
Future<T> snapshotFirst<T>(
  Ref ref,
  String key, {
  required Future<T> Function() fetch,
  required Object? Function(T value) encode,
  required T Function(Object? json) decode,
}) async {
  final pending = _pending.remove(key);
  if (pending != null) {
    final value = await pending as T;
    unawaited(SnapshotCache.write(key, encode(value)));
    return value;
  }
  if (SnapshotCache._used.add(key)) {
    final cached = await SnapshotCache.read(key);
    if (cached != null) {
      try {
        final value = decode(cached);
        // 不能马上 invalidate：快照还没来得及通知到界面就会被重新加载覆盖掉。等后台拉完再刷新
        final latest = fetch();
        _pending[key] = latest;
        latest.then(
          (_) => ref.invalidateSelf(),
          onError: (Object e) {
            // 拉取失败：继续显示快照，下次刷新再试
            _pending.remove(key);
            debugPrint('snapshot $key refresh failed: $e');
          },
        );
        return value;
      } catch (_) {}
    }
  }
  final value = await fetch();
  unawaited(SnapshotCache.write(key, encode(value)));
  return value;
}
