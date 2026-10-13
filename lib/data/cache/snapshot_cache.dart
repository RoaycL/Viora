import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/log/load_metrics.dart';

/// 页面数据快照（继续观看、收藏、观看记录…）：每次从服务器拉到新数据就存一份到磁盘。
/// 下次打开应用时先显示上次的快照（秒开），同时在后台重新拉取，拉到后再替换。
abstract final class SnapshotCache {
  static Future<Directory?>? _dir;
  static int _epoch = 0;
  static final _writes = <String, Future<void>>{};

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

  static Future<void> write(String key, Object? json, {bool Function()? isCurrent}) {
    final epoch = _epoch;
    bool valid() => epoch == _epoch && (isCurrent?.call() ?? true);
    final previous = _writes[key] ?? Future<void>.value();
    final next = previous.then((_) async {
      if (!valid()) return;
      File? tmp;
      try {
        final d = await _directory();
        if (d == null || !valid()) return;
        tmp = File('${d.path}/$key.json.tmp');
        await tmp.writeAsString(jsonEncode(json), flush: true);
        if (!valid()) return;
        await tmp.rename('${d.path}/$key.json');
      } catch (e) {
        debugPrint('snapshot write failed: ${e.runtimeType}');
      } finally {
        try {
          if (tmp != null && await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
    });
    _writes[key] = next;
    next.whenComplete(() {
      if (identical(_writes[key], next)) _writes.remove(key);
    });
    return next;
  }

  /// 删除所有快照（如退出登录、清除缓存）
  static Future<void> clear() async {
    _epoch++;
    _used.clear();
    _ready.clear();
    _owners.clear();
    _pending.clear();
    _sourceOwners.clear();
    await Future.wait(_writes.values.toList());
    try {
      final d = await _directory();
      if (d != null && await d.exists()) await d.delete(recursive: true);
      _dir = null;
    } catch (_) {}
  }

  @visibleForTesting
  static void resetForTest() {
    _epoch++;
    _used.clear();
    _pending.clear();
    _ready.clear();
    _owners.clear();
    _sourceOwners.clear();
    _dir = null;
  }

  @visibleForTesting
  static set directoryForTest(Directory d) => _dir = Future.value(d);
}

enum SnapshotStatus { cached, fresh, failed, incomplete }

class SnapshotFetch<T> {
  const SnapshotFetch(this.value, {this.complete = true});
  final T value;
  final bool complete;
}

class SnapshotSource<T> {
  const SnapshotSource({
    required this.key,
    required this.id,
    required this.fetch,
    required this.encode,
    required this.decode,
  });
  final String key;
  final String id;
  final Future<SnapshotFetch<T>> Function() fetch;
  final Object? Function(T) encode;
  final T Function(Object?) decode;
}

class SourceSnapshot<T> {
  const SourceSnapshot({required this.id, required this.status, this.value, this.refreshedAt});
  final String id;
  final SnapshotStatus status;
  final T? value;
  final DateTime? refreshedAt;
}

class SnapshotBatch<T> {
  const SnapshotBatch(this.sources);
  final List<SourceSnapshot<T>> sources;
  int get failures =>
      sources.where((s) => s.status == SnapshotStatus.failed || s.status == SnapshotStatus.incomplete).length;
  bool get refreshing => sources.any((s) => s.status == SnapshotStatus.cached);
}

final _ready = <String, Object>{};
final _owners = <String, Object>{};
final _sourceOwners = <String, Object>{};

/// 首次加载先读各来源快照；完整成功才替换该来源，失败和不完整响应保留它的旧快照。
Future<SnapshotBatch<T>> sourceSnapshotsFirst<T>(
  Ref ref,
  String groupKey, {
  required String operation,
  required List<SnapshotSource<T>> sources,
}) async {
  final ready = _ready.remove(groupKey);
  if (ready != null) return ready as SnapshotBatch<T>;
  final owner = Object();
  final epoch = SnapshotCache._epoch;
  _owners[groupKey] = owner;
  var active = true;
  var refreshingSelf = false;
  bool current() => active && epoch == SnapshotCache._epoch && identical(_owners[groupKey], owner);
  ref.onDispose(() {
    active = false;
    if (identical(_owners[groupKey], owner)) {
      _owners.remove(groupKey);
      if (!refreshingSelf) _ready.remove(groupKey);
    }
  });
  final trace = LoadTrace(operation);
  final firstLoad = SnapshotCache._used.add(groupKey);
  final cached = await Future.wait(
    sources.map((s) async {
      final json = await SnapshotCache.read(s.key);
      try {
        final envelope = json as Map;
        if (envelope['version'] != 2) throw const FormatException();
        return SourceSnapshot<T>(
          id: s.id,
          status: SnapshotStatus.cached,
          value: s.decode(envelope['data']),
          refreshedAt: DateTime.tryParse(envelope['at'] as String? ?? ''),
        );
      } catch (_) {
        return SourceSnapshot<T>(id: s.id, status: SnapshotStatus.cached);
      }
    }),
  );
  if (!current()) return SnapshotBatch(cached);
  trace.event('cache', sources: sources.length, cached: cached.where((s) => s.value != null).length);
  Future<SnapshotBatch<T>> refresh() async {
    var first = true;
    final fresh = await Future.wait([
      for (var i = 0; i < sources.length; i++)
        () async {
          final source = sources[i];
          final sourceOwner = Object();
          _sourceOwners[source.key] = sourceOwner;
          bool valid() => current() && identical(_sourceOwners[source.key], sourceOwner);
          try {
            final fetched = await LoadTrace.request(operation, source.id, source.fetch);
            if (first && current()) {
              first = false;
              trace.event('first_remote', sources: sources.length);
            }
            if (!fetched.complete) {
              return SourceSnapshot<T>(
                id: source.id,
                status: SnapshotStatus.incomplete,
                value: cached[i].value ?? fetched.value,
                refreshedAt: cached[i].refreshedAt,
              );
            }
            final at = DateTime.now();
            if (valid()) {
              await SnapshotCache.write(source.key, {
                'version': 2,
                'at': at.toIso8601String(),
                'data': source.encode(fetched.value),
              }, isCurrent: valid);
            }
            return SourceSnapshot<T>(
              id: source.id,
              status: SnapshotStatus.fresh,
              value: fetched.value,
              refreshedAt: at,
            );
          } catch (_) {
            return SourceSnapshot<T>(
              id: source.id,
              status: SnapshotStatus.failed,
              value: cached[i].value,
              refreshedAt: cached[i].refreshedAt,
            );
          } finally {
            if (identical(_sourceOwners[source.key], sourceOwner)) _sourceOwners.remove(source.key);
          }
        }(),
    ]);
    final result = SnapshotBatch(fresh);
    if (current()) trace.event('complete', sources: sources.length, failed: result.failures);
    return result;
  }

  final latest = refresh();
  if (firstLoad && cached.any((s) => s.value != null)) {
    latest.then((result) {
      if (!current()) return;
      _ready[groupKey] = result;
      refreshingSelf = true;
      ref.invalidateSelf();
    });
    trace.event('first_data', cached: cached.where((s) => s.value != null).length);
    return SnapshotBatch(cached);
  }
  final result = await latest;
  if (current()) trace.event('first_data', sources: sources.length, failed: result.failures);
  return result;
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
