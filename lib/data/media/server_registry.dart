import 'dart:async';
import 'dart:math' as math;

import '../../player/preload.dart';
import '../history/play_history.dart';

import '../cache/account_scope.dart';
import '../cache/snapshot_cache.dart' show SnapshotBatch;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../config/config_store.dart';
import '../emby/emby_client.dart';
import 'media_models.dart';
import 'media_feed.dart';

export 'media_feed.dart' show MediaFeedKind, MediaFeedResult;

/// 应用版本号（main() 启动时从 package_info 读入；测试中保持默认值）。
String appVersion = '0.0.0';

/// 按服务器 ID 取客户端。配置变化（登录令牌、线路、代理、UA）时自动重建。
final serverClientProvider = Provider.family<EmbyClient?, String>((ref, serverId) {
  // 只在这台服务器的连接信息（登录、线路、代理、UA）变化时重建。
  // 测速延迟、片量、访问时间等写回配置时不重建，避免依赖它的列表全部重新请求服务器。
  ref.watch(configProvider.select((c) => c.clientKey(serverId)));
  final config = ref.read(configProvider);
  final server = config.server(serverId);
  if (server == null || !server.loggedIn) {
    PlayHistory.unbindAccount(serverId);
    PlaybackPreloader.unbindAccount(serverId);
  }
  if (server == null) return null;
  if (server.loggedIn) {
    PlayHistory.bindAccount(serverId, accountScope(server), legacy: legacyAccountScope(server));
    PlaybackPreloader.bindAccount(serverId, accountScope(server));
  }
  final store = ref.read(configProvider.notifier);
  return mediaServerClient(
    config: config,
    server: server,
    appVersion: appVersion,
    onProbed: (reachable) {
      if (ref.mounted) {
        // 用户手动测速（服务器页、改地址后）：结果立即生效，并作废还在进行的后台测速
        ref
            .read(serverReachabilityProvider.notifier)
            .record(serverId, config.clientKey(serverId), reachable, manual: true);
      }
    },
    onServerChanged: (s) => store.updateServer(
      s.id,
      (old) => accountScope(old) != accountScope(server)
          ? old
          : old.copyWith(token: s.token, userId: s.userId, lines: s.lines, clearSession: s.token == null),
    ),
  );
});

/// 本次运行中已确认不可用的服务器。旧线路、旧账号的测速结果不用于新的连接配置。
final serverReachabilityProvider = NotifierProvider<ServerReachability, Map<String, String>>(ServerReachability.new);

class ServerReachability extends Notifier<Map<String, String>> {
  /// 离线后复测的间隔：先快后慢（刚开机网络还没连好时很快就能恢复），最长半小时
  static const retryIntervals = [
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 20),
    Duration(minutes: 30),
  ];
  static const _failureCheckCooldown = Duration(minutes: 1);
  final _retries = <String, Timer>{};

  /// 每台服务器连续复测失败的次数（决定下一次复测间隔）
  final _failedChecks = <String, int>{};

  /// 每台服务器的手动测速代次：后台测速开始后用户手动测过，后台的旧结果作废，不覆盖手动结果
  final _epochs = <String, int>{};
  int epochOf(String id) => _epochs[id] ?? 0;
  Timer? _check;
  final _pendingChecks = <String, ({String key, bool offline})>{};
  final _lastFailureCheck = <String, ({String key, DateTime at})>{};
  bool get _active => ref.mounted;

  @override
  Map<String, String> build() {
    ref.onDispose(() {
      for (final timer in _retries.values) {
        timer.cancel();
      }
      _check?.cancel();
    });
    return const {};
  }

  bool _isCurrent(AppConfig config, String id, String key) =>
      config.server(id)?.loggedIn == true && config.clientKey(id) == key;

  /// [manual]：用户手动测速的结果，优先于正在进行的后台测速；[epoch]：后台测速开始时的 [epochOf]，期间有过手动测速就丢弃
  void record(String id, String connectionKey, bool reachable, {bool manual = false, int? epoch}) {
    if (!_isCurrent(ref.read(configProvider), id, connectionKey)) return;
    if (manual) {
      _epochs[id] = epochOf(id) + 1;
    } else if (epoch != null && epoch != epochOf(id)) {
      return;
    }
    if (reachable) {
      _retries.remove(id)?.cancel();
      _failedChecks.remove(id);
      if (state.containsKey(id)) state = {...state}..remove(id);
      return;
    }
    if (state[id] != connectionKey) {
      _retries.remove(id)?.cancel();
      _failedChecks.remove(id);
      state = {...state, id: connectionKey};
    } else if (manual) {
      // 手动测过仍然不通：从最短间隔重新开始复测
      _retries.remove(id)?.cancel();
      _failedChecks.remove(id);
    }
    _scheduleRetry(id, connectionKey);
  }

  /// 应用回到前台（电视唤醒、电脑解锁等，网络可能刚恢复）：立即复测所有离线服务器
  void recheckOffline() {
    if (!_active) return;
    final config = ref.read(configProvider);
    for (final entry in state.entries) {
      if (!_isCurrent(config, entry.key, entry.value)) continue;
      _retries.remove(entry.key)?.cancel();
      _failedChecks.remove(entry.key);
      _queueCheck(entry.key, entry.value, offline: true);
    }
  }

  /// 连接失败只触发测速；权限、资源不存在等错误不影响整台服务器的状态。
  /// 返回 true 时，本轮可停止向这台服务器尝试其他关键词。
  bool reportAggregateFailure(EmbyClient client, Object error) {
    final suspect =
        error is TimeoutException ||
        error is MediaServerException && (error.connectionFailure || const {502, 503, 504}.contains(error.statusCode));
    if (!suspect) return false;
    final id = client.server.id;
    final key = client.config.clientKey(id);
    if (!_isCurrent(ref.read(configProvider), id, key) || state[id] == key) return true;
    final now = DateTime.now();
    final last = _lastFailureCheck[id];
    if (last != null && last.key == key && now.difference(last.at) < _failureCheckCooldown) return true;
    _lastFailureCheck[id] = (key: key, at: now);
    _queueCheck(id, key, offline: false);
    return true;
  }

  void _scheduleRetry(String id, String key) {
    _retries.putIfAbsent(id, () {
      final n = _failedChecks[id] ?? 0;
      _failedChecks[id] = n + 1;
      return Timer(retryIntervals[n.clamp(0, retryIntervals.length - 1)], () {
        _retries.remove(id);
        if (state[id] == key) _queueCheck(id, key, offline: true);
      });
    });
  }

  void _queueCheck(String id, String key, {required bool offline}) {
    _pendingChecks[id] = (key: key, offline: offline);
    _check ??= Timer(Duration.zero, _checkServers);
  }

  Future<void> _checkServers() async {
    try {
      while (_active && _pendingChecks.isNotEmpty) {
        final config = ref.read(configProvider);
        final candidates = {
          for (final entry in _pendingChecks.entries)
            if (_isCurrent(config, entry.key, entry.value.key) &&
                (state[entry.key] == entry.value.key) == entry.value.offline)
              entry.key: entry.value,
        };
        // 连接配置已经变了的离线记录：作废（不再复测它，留着的话配置改回去时会一直被排除而没人复测）
        final stale = [
          for (final entry in _pendingChecks.entries)
            if (state[entry.key] == entry.value.key && !_isCurrent(config, entry.key, entry.value.key)) entry.key,
        ];
        if (stale.isNotEmpty) {
          state = {...state}..removeWhere((id, _) => stale.contains(id));
          for (final id in stale) {
            _failedChecks.remove(id);
          }
        }
        _pendingChecks.clear();
        if (candidates.isEmpty) continue;
        await probeAllServers(ref.container, concurrency: 4, only: candidates.keys.toSet());
        if (!_active) return;
        // 单台测速异常时也保留已经确认的离线状态，并继续定时复测。
        final latest = ref.read(configProvider);
        for (final entry in candidates.entries) {
          final key = entry.value.key;
          if (state[entry.key] == key && _isCurrent(latest, entry.key, key)) _scheduleRetry(entry.key, key);
        }
      }
    } finally {
      _check = null;
    }
  }
}

final availableAggregateServerIdsProvider = Provider<Set<String>>((ref) {
  final config = ref.watch(configProvider);
  final offline = ref.watch(serverReachabilityProvider);
  return {
    for (final server in config.servers)
      if (server.aggregate && server.loggedIn && offline[server.id] != config.clientKey(server.id)) server.id,
  };
});

/// 启动时给所有服务器测速：同时最多测 [concurrency] 台，全部测完后把延迟合并成一次配置保存。
/// 每台测完各保存一次的话，十几台服务器就是首页加载期间十几次配置写入和界面刷新
Future<void> probeAllServers(
  ProviderContainer container, {
  required int concurrency,
  Duration timeout = const Duration(seconds: 10),
  Set<String>? only,
}) async {
  final read = container.read;
  final reachability = read(serverReachabilityProvider.notifier);
  final pending = read(configProvider).servers.where((s) => only == null || only.contains(s.id)).toList();
  final latency = <String, ({String connectionKey, int epoch, Map<String, int?> lines})>{};
  Future<void> worker() async {
    while (pending.isNotEmpty && reachability._active) {
      final s = pending.removeAt(0);
      try {
        final connectionKey = read(configProvider).clientKey(s.id);
        final epoch = reachability.epochOf(s.id);
        final probed = await read(serverClientProvider(s.id))?.probeAll(notify: false, timeout: timeout);
        if (probed == null || !reachability._active) continue;
        final lines = {for (final line in probed.lines) line.id: line.latencyMs};
        latency[s.id] = (connectionKey: connectionKey, epoch: epoch, lines: lines);
        reachability.record(s.id, connectionKey, lines.values.any((ms) => ms != null), epoch: epoch);
      } catch (_) {}
    }
  }

  await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  if (!reachability._active) return;
  final config = read(configProvider);
  latency.removeWhere((id, result) {
    final server = config.server(id);
    return server == null ||
        config.clientKey(id) != result.connectionKey ||
        // 测速期间用户手动测过：保留手动测速的延迟
        reachability.epochOf(id) != result.epoch ||
        !server.lines.any((l) => result.lines.containsKey(l.id) && result.lines[l.id] != l.latencyMs);
  });
  if (latency.isEmpty) return;
  await container
      .read(configProvider.notifier)
      .update(
        (c) => c.copyWith(
          servers: [
            for (final s in c.allServers)
              if (latency[s.id] case final probed?)
                s.copyWith(
                  lines: [
                    for (final l in s.lines)
                      // 测速期间新加的线路没有结果：保持原样
                      probed.lines.containsKey(l.id)
                          ? l.copyWith(latencyMs: probed.lines[l.id], clearLatency: probed.lines[l.id] == null)
                          : l,
                  ],
                )
              else
                s,
          ],
        ),
      );
}

/// 为新服务器（还未保存）创建客户端，用于添加服务器时的连接测试与登录。
EmbyClient clientForDraft(AppConfig config, ServerConfig server) =>
    mediaServerClient(config: config, server: server, appVersion: appVersion);

typedef MediaFeedKey = ({MediaFeedKind kind, String scope});

final mediaFeedScopeProvider = Provider<String>((ref) => ref.watch(configProvider.select(mediaFeedScope)));

class MediaFeedRefresh extends Notifier<Map<MediaFeedKind, int>> {
  @override
  Map<MediaFeedKind, int> build() => const {};
  void refresh(MediaFeedKind kind) => state = {...state, kind: (state[kind] ?? 0) + 1};
}

final mediaFeedRefreshProvider = NotifierProvider<MediaFeedRefresh, Map<MediaFeedKind, int>>(MediaFeedRefresh.new);

final mediaFeedProvider = FutureProvider.autoDispose.family<MediaFeedResult, MediaFeedKey>((ref, key) {
  ref.watch(mediaFeedRefreshProvider.select((s) => s[key.kind] ?? 0));
  final config = ref.read(configProvider);
  if (key.scope != mediaFeedScope(config)) return const MediaFeedResult(SnapshotBatch<List<MediaItem>>([]));
  final clients = [
    for (final server in config.servers.where((s) => s.loggedIn)) ?ref.watch(serverClientProvider(server.id)),
  ];
  return loadMediaFeed(ref, key.kind, key.scope, config, clients);
});

/// 切换账号 / 家长模式时切换 family 实例，避免 AsyncValue 继续携带上一账号的值。
final mediaFeedStateProvider = Provider.family<AsyncValue<MediaFeedResult>, MediaFeedKind>((ref, kind) {
  final scope = ref.watch(mediaFeedScopeProvider);
  return ref.watch(mediaFeedProvider((kind: kind, scope: scope)));
});

/// 刚在本机播放过的条目：退出播放后继续观看马上按本机的进度显示（排到最前、进度更新，看完的移出），
/// 不用等所有服务器刷新回来（慢的服务器要等到超时）。只保留 [ttl]，之后以服务器的数据为准
class LocalPlays extends Notifier<Map<String, (MediaItem, DateTime)>> {
  static const ttl = Duration(minutes: 2);
  Timer? _expiry;

  @override
  Map<String, (MediaItem, DateTime)> build() {
    ref.onDispose(() => _expiry?.cancel());
    return const {};
  }

  void record(MediaItem item) {
    final now = DateTime.now();
    state = {
      for (final e in state.entries)
        if (now.difference(e.value.$2) < ttl) e.key: e.value,
      '${item.serverId}/${item.id}': (item, now),
    };
    _expiry?.cancel();
    _expiry = Timer(ttl, () {
      final now = DateTime.now();
      state = {
        for (final e in state.entries)
          if (now.difference(e.value.$2) < ttl) e.key: e.value,
      };
    });
  }
}

final localPlaysProvider = NotifierProvider<LocalPlays, Map<String, (MediaItem, DateTime)>>(LocalPlays.new);

/// 服务器的记录 + 本机刚播放过的（本机的覆盖同一条目，新看的加进来；看完的也保留，继续观看就是观看记录）
List<MediaItem> mergeLocalPlays(List<MediaItem> server, Map<String, (MediaItem, DateTime)> local) {
  if (local.isEmpty) return server;
  final seen = <String>{};
  final out = [
    for (final it in server)
      if (seen.add('${it.serverId}/${it.id}')) local['${it.serverId}/${it.id}']?.$1 ?? it,
  ];
  for (final e in local.entries) {
    final mine = e.value.$1;
    if (!seen.contains(e.key) && (mine.played || mine.position > Duration.zero)) out.add(mine);
  }
  return out;
}

final resumeProvider = Provider<AsyncValue<List<MediaItem>>>((ref) {
  final config = ref.read(configProvider);
  final local = ref.watch(localPlaysProvider);
  return ref.watch(mediaFeedStateProvider(MediaFeedKind.resume)).whenData((snapshot) {
    final all = mergeLocalPlays(snapshot.items, local).where((it) => itemVisible(config, it)).toList();
    final epoch = DateTime(1970);
    all.sort((a, b) => (PlayHistory.lastPlayed(b) ?? epoch).compareTo(PlayHistory.lastPlayed(a) ?? epoch));
    return all;
  });
});

/// 首页「继续观看」：没看完的 + 最近看完的（看完了也保留，相当于观看记录），按上次播放时间排，最多 [limit] 条。
/// 剧集只留最近的一集（由首页去重）
final continueWatchingProvider = Provider<AsyncValue<List<MediaItem>>>((ref) {
  const limit = 40;
  final config = ref.read(configProvider);
  final resume = ref.watch(resumeProvider);
  final played = ref.watch(mediaFeedStateProvider(MediaFeedKind.recentlyPlayed));
  final local = ref.watch(localPlaysProvider);
  return resume.whenData((inProgress) {
    final seen = {for (final it in inProgress) '${it.serverId}/${it.id}'};
    final finished = mergeLocalPlays(
      played.value?.items ?? const <MediaItem>[],
      local,
    ).where((it) => seen.add('${it.serverId}/${it.id}') && itemVisible(config, it)).toList();
    final epoch = DateTime(1970);
    return [...inProgress, ...finished]
      ..sort((a, b) => (PlayHistory.lastPlayed(b) ?? epoch).compareTo(PlayHistory.lastPlayed(a) ?? epoch))
      ..length = math.min(limit, inProgress.length + finished.length);
  });
});

final librariesProvider = FutureProvider.family<List<Library>, String>((ref, serverId) async {
  final client = ref.watch(serverClientProvider(serverId));
  if (client == null) return const [];
  return client.libraries();
});

final latestProvider = FutureProvider.family<List<MediaItem>, ({String serverId, String libraryId})>((ref, key) async {
  final client = ref.watch(serverClientProvider(key.serverId));
  if (client == null) return const [];
  return client.latest(parentId: key.libraryId, limit: 16);
});

/// 卡片上已有的条目信息（首页各行、媒体库、搜索结果的字段和单条详情一样）：
/// 打开详情页时先用它显示，不等这台服务器返回；这台服务器出错时页面照样能打开，资源从其他服务器聚合
class ItemSeeds {
  static final _items = <String, MediaItem>{};

  static void remember(MediaItem item) {
    final key = '${item.serverId}/${item.id}';
    _items
      ..remove(key)
      ..[key] = item;
    if (_items.length > 200) _items.remove(_items.keys.first);
  }

  static MediaItem? of(String serverId, String itemId) => _items['$serverId/$itemId'];

  /// 换账号 / 家长控制变化后旧卡片的信息不再可信
  static void clear() => _items.clear();
}

final itemProvider = FutureProvider.family<MediaItem, ({String serverId, String itemId})>((ref, key) async {
  final client = ref.watch(serverClientProvider(key.serverId));
  if (client == null) throw const MediaServerException('服务器不存在');
  return client.item(key.itemId);
});

/// 当前能显示的条目：所在服务器可见（儿童模式隐藏 R18 服务器），分级在允许范围内（单集跟随剧集）
bool itemVisible(AppConfig c, MediaItem it) =>
    c.server(it.serverId) != null &&
    (!c.parental.enabled || !c.server(it.serverId)!.adult) &&
    (!c.parental.enabled || it.kind == MediaKind.episode || c.parental.allows(it.officialRating));
