import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log/app_log.dart';
import '../cache/account_scope.dart';
import '../emby/emby_client.dart';
import '../config/config_store.dart';
import '../media/server_registry.dart';
import 'media_index.dart';

/// 索引数据库（Web 上为 null，聚合功能退化为实时搜索）。
/// 整个应用只打开一次：服务器登录 / 退出、换账号时在同一个库上重新绑定账号（清掉变化的服务器），
/// 不关闭重开——重开期间页面还会拿到已关闭的旧库去查询（首页「最近入库」闪空、删除服务器报错）。
final mediaIndexProvider = FutureProvider<MediaIndex?>((ref) async {
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
  index?.bindAccounts(
    indexAccountScopes(ref.read(configProvider)),
    legacy: legacyIndexAccountScopes(ref.read(configProvider)),
  );
  if (index != null) {
    ref.listen(configProvider.select(indexAccountsKey), (prev, next) {
      if (prev == next || index.isClosed) return;
      index.bindAccounts(indexAccountScopes(ref.read(configProvider)));
      ref.invalidate(indexRevisionProvider);
    });
  }
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
          // 同步期间服务器新入库：按入库时间升序分页，新条目排在最后，前面的分页位置不变，接着同步到新的总数即可。
          // 全量同步时总数变少（有条目被删）会让后面的分页整体前移、漏掉条目，而全量结束会删除没出现的条目，所以只能放弃重来；
          // 增量同步漏掉的条目下次增量还会拿到，照常继续。
          if (total != null && page.total < total && full) throw const MediaServerException('索引分页总数变少，请重试');
          total = page.total;
        }
        final fresh = [
          for (final item in page.items)
            if (seen.add(item.id)) item,
        ];
        // 全量同步出现重复说明分页错位（可能漏条目），放弃重来；增量同步跳过重复即可
        if (full && fresh.length != page.items.length) throw const MediaServerException('索引分页重复，请重试');
        if (page.receivedCount == 0 && total != null && start != total) {
          throw const MediaServerException('索引分页响应不完整，请重试');
        }
        // 拼音、标题归一化、JSON 在后台算（16 台服务器同步时不卡界面），主线程只写库
        final rows = await compute(prepareIndexRows, fresh);
        if (!current()) return;
        index.upsertPrepared(serverId, rows, gen: gen);
        start += page.receivedCount;
        _set(serverId, SyncStatus(running: true, done: start, total: total, count: index.count(serverId)));
        if (total != null && start > total && full) throw const MediaServerException('索引分页数量不一致，请重试');
        if (page.receivedCount == 0 || (total != null && start >= total)) break;
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
