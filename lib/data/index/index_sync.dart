import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log/app_log.dart';
import '../cache/account_scope.dart';
import '../emby/emby_client.dart';
import '../config/config_store.dart';
import '../media/server_registry.dart';
import 'media_index.dart';

/// 索引数据库（Web 上为 null，聚合功能退化为实时搜索）
final mediaIndexProvider = FutureProvider<MediaIndex?>((ref) async {
  ref.watch(configProvider.select(indexAccountsKey));
  var active = true;
  MediaIndex? opened;
  ref.onDispose(() {
    active = false;
    opened?.close();
  });
  final index = await MediaIndex.open();
  opened = index;
  if (!active) {
    index?.close();
    return null;
  }
  index?.bindAccounts(indexAccountScopes(ref.read(configProvider)));
  return index;
});

@immutable
class SyncStatus {
  const SyncStatus({this.running = false, this.done = 0, this.total, this.error, this.count = 0, this.fullAt});

  final bool running;
  final int done;
  final int? total;
  final String? error;

  /// 索引里这台服务器的条目数
  final int count;
  final DateTime? fullAt;
}

/// 索引同步（docs/04-aggregation.md §2）：
/// 添加服务器 / 超过 7 天 → 全量；平时启动 → 按 MinDateLastSaved 增量。
class IndexSyncController extends Notifier<Map<String, SyncStatus>> {
  final _runningScopes = <String, String>{};
  bool _active = true;

  /// 每页条数与页间隔：后台慢慢同步，避免 NAS 一下子满负载
  static const _pageSize = 200;
  static const _pagePause = Duration(milliseconds: 400);
  static const _fullEvery = Duration(days: 7);

  @override
  Map<String, SyncStatus> build() {
    _active = true;
    ref.onDispose(() {
      _active = false;
      _runningScopes.clear();
    });
    return const {};
  }

  void _set(String id, SyncStatus s) => state = {...state, id: s};

  /// 启动时调用：同步所有已登录服务器（依次进行，避免同时压多台服务器）
  Future<void> syncAll({bool forceFull = false}) async {
    final index = await ref.read(mediaIndexProvider.future);
    if (index == null) return;
    final servers = ref.read(configProvider).servers;
    index.retainServers(indexAccountScopes(ref.read(configProvider)).keys.toSet());
    for (final s in servers) {
      if (!s.loggedIn) continue;
      await syncServer(s.id, forceFull: forceFull);
    }
  }

  Future<void> syncServer(String serverId, {bool forceFull = false}) async {
    final index = await ref.read(mediaIndexProvider.future);
    final client = ref.read(serverClientProvider(serverId));
    if (index == null || client == null) return;
    final scope = accountScope(client.server);
    if (_runningScopes[serverId] == scope) return;
    _runningScopes[serverId] = scope;
    bool current() =>
        _active &&
        _runningScopes[serverId] == scope &&
        index.hasAccount(serverId, scope) &&
        ref.read(configProvider).server(serverId)?.loggedIn == true &&
        accountScope(ref.read(configProvider).server(serverId)!) == scope;
    if (!current()) {
      if (_runningScopes[serverId] == scope) _runningScopes.remove(serverId);
      return;
    }

    final st = index.syncState(serverId);
    final full = forceFull || st.fullAt == null || DateTime.now().difference(st.fullAt!) > _fullEvery;
    final startedAt = DateTime.now();
    final gen = full ? index.beginFull(serverId) : st.gen;
    _set(serverId, SyncStatus(running: true, count: index.count(serverId), fullAt: st.fullAt));
    AppLog.add('[index] ${client.server.name} ${full ? '全量' : '增量'}同步开始');
    try {
      var start = 0;
      int? total;
      final seen = <String>{};
      while (true) {
        final page = await client.items(
          start: start,
          limit: _pageSize,
          sortBy: 'DateCreated,SortName',
          sortOrder: 'Ascending',
          minDateLastSaved: full ? null : st.incrAt?.subtract(const Duration(minutes: 5)),
          fields: EmbyClient.indexFields,
          userData: false,
        );
        if (page.totalKnown) {
          if (total != null && total != page.total) throw const MediaServerException('索引分页总数变化，请重试');
          total = page.total;
        }
        if (page.items.any((item) => !seen.add(item.id))) {
          throw const MediaServerException('索引分页重复，请重试');
        }
        if (page.receivedCount == 0 && total != null && start != total) {
          throw const MediaServerException('索引分页响应不完整，请重试');
        }
        // 拼音、标题归一化、JSON 在后台算（16 台服务器同步时不卡界面），主线程只写库
        final rows = await compute(prepareIndexRows, page.items);
        if (!current()) return;
        index.upsertPrepared(serverId, rows, gen: gen);
        start += page.receivedCount;
        _set(serverId, SyncStatus(running: true, done: start, total: total, count: index.count(serverId)));
        if (total != null && start > total) throw const MediaServerException('索引分页数量不一致，请重试');
        if (page.receivedCount == 0 || (total != null && start == total)) break;
        if (!page.totalKnown && page.items.isEmpty) {
          throw const MediaServerException('索引分页缺少总数且无可用条目，请重试');
        }
        await Future<void>.delayed(_pagePause);
      }
      if (!current()) return;
      if (full) {
        index.finishFull(serverId, gen);
      } else {
        index.finishIncremental(serverId, startedAt);
      }
      _set(
        serverId,
        SyncStatus(done: start, total: total, count: index.count(serverId), fullAt: index.syncState(serverId).fullAt),
      );
      AppLog.add(
        '[index] ${client.server.name} 同步完成：$start 条，'
        '${DateTime.now().difference(startedAt).inMilliseconds} ms',
      );
      // 增量同步没有新内容时不刷新（否则启动时每同步完一台服务器，首页「最近入库」等就重算、重建一次）
      if (full || start > 0) ref.invalidate(indexRevisionProvider);
    } catch (e) {
      if (!current()) return;
      debugPrint('index sync ${client.server.name} failed: $e');
      _set(serverId, SyncStatus(error: e.toString(), count: index.count(serverId), fullAt: st.fullAt));
    } finally {
      if (_active && _runningScopes[serverId] == scope) {
        if (!current()) _set(serverId, const SyncStatus());
        _runningScopes.remove(serverId);
      }
    }
  }

  void forget(String serverId) {
    ref.read(mediaIndexProvider).value?.removeServer(serverId);
    state = {...state}..remove(serverId);
  }
}

final indexSyncProvider = NotifierProvider<IndexSyncController, Map<String, SyncStatus>>(IndexSyncController.new);

/// 索引内容变化时递增，依赖索引查询的 provider watch 它来刷新
final indexRevisionProvider = Provider<int>((ref) => DateTime.now().millisecondsSinceEpoch);
