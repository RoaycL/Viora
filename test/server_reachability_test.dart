import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/data/aggregate/tmdb_link.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/index/index_sync.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/data/media/server_registry.dart';

const _server = ServerConfig(
  id: 's',
  type: ServerType.emby,
  name: '服务器',
  username: 'me',
  token: 'tok',
  userId: 'uid',
  lines: [ServerLine(id: 'l', name: '线路', url: 'http://server.example')],
);

class _ProbeClient extends EmbyClient {
  _ProbeClient(AppConfig config) : super(config: config, server: _server, appVersion: 'test');

  int calls = 0;
  int searches = 0;
  bool reachable = false;
  Object? searchError;

  @override
  Future<ServerConfig> probeAll({bool notify = true, Duration? timeout}) async {
    calls++;
    return reachable ? _server.copyWith(lines: [_server.lines.single.copyWith(latencyMs: 12)]) : _server;
  }

  @override
  Future<PagedItems> items({
    String? parentId,
    String types = 'Movie,Series',
    int start = 0,
    int limit = 60,
    String sortBy = 'DateCreated,SortName',
    String sortOrder = 'Descending',
    String? searchTerm,
    DateTime? minDateLastSaved,
    String? filters,
    String? fields,
    bool userData = true,
  }) async {
    searches++;
    if (searchError case final error?) throw error;
    return const PagedItems([], 0);
  }
}

void main() {
  testWidgets('离线检测不沿用旧线路，后台复测成功后恢复聚合', (tester) async {
    SharedPreferences.setMockInitialValues({});
    ConfigStore.vault = MemoryVault();
    const config = AppConfig(servers: [_server]);
    final client = _ProbeClient(config);
    final container = ProviderContainer(overrides: [serverClientProvider.overrideWith((ref, id) => client)]);
    addTearDown(container.dispose);
    final store = container.read(configProvider.notifier);
    await store.update((_) => config);
    expect(container.read(availableAggregateServerIdsProvider), {'s'}, reason: '未测速时照常参与');
    await probeAllServers(container, concurrency: 1);
    expect(container.read(availableAggregateServerIdsProvider), isEmpty);

    await store.updateServer('s', (s) => s.copyWith(lines: [s.lines.single.copyWith(url: 'http://new.example')]));
    expect(container.read(availableAggregateServerIdsProvider), {'s'}, reason: '旧线路的失败不能屏蔽新线路');
    final newConfig = container.read(configProvider);
    final reachability = container.read(serverReachabilityProvider.notifier);
    reachability.record('s', config.clientKey('s'), false);
    expect(container.read(availableAggregateServerIdsProvider), {'s'});
    reachability.record('s', newConfig.clientKey('s'), false);
    expect(container.read(availableAggregateServerIdsProvider), isEmpty);

    client.reachable = true;
    await tester.pump(const Duration(minutes: 9, seconds: 59));
    expect(client.calls, 1, reason: '不到十分钟不复测');
    await tester.pump(const Duration(seconds: 1));
    expect(client.calls, 2);
    expect(container.read(availableAggregateServerIdsProvider), {'s'});
    await tester.pump(ServerReachability.retryInterval);
    expect(client.calls, 2, reason: '已经恢复时停止后台复测');
  });

  testWidgets('聚合请求遇到连接错误后，在后台确认并跳过故障服务器', (tester) async {
    SharedPreferences.setMockInitialValues({});
    ConfigStore.vault = MemoryVault();
    const config = AppConfig(servers: [_server]);
    final client = _ProbeClient(config);
    final container = ProviderContainer(
      overrides: [
        serverClientProvider.overrideWith((ref, id) => client),
        mediaIndexProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    await container.read(configProvider.notifier).update((_) => config);
    final reachability = container.read(serverReachabilityProvider.notifier);
    TmdbSearchKey key(int id) => (isTv: false, id: id, title: '标题', originalTitle: 'Original', year: 2026);
    Future<List<MediaItem>> search(int id) {
      final provider = tmdbLibrarySearchProvider(key(id));
      container.listen(provider, (_, _) {});
      return container.read(provider.future);
    }

    expect(await search(1), isEmpty);
    client.searchError = const MediaServerException('没权限', statusCode: 403);
    expect(await search(2), isEmpty);
    await tester.pump();
    expect(client.calls, 0);
    expect(client.searches, 4);

    client.searchError = const MediaServerException('无法连接服务器', connectionFailure: true);
    expect(await search(3), isEmpty);
    expect(client.searches, 5, reason: '连接失败后不再请求第二个关键词');
    expect(client.calls, 0, reason: '聚合先结束，测速在后台');
    expect(reachability.reportAggregateFailure(client, client.searchError!), isTrue);
    await tester.pump(const Duration(milliseconds: 1));
    expect(client.calls, 1, reason: '同一台服务器的失败合并测速');
    expect(container.read(availableAggregateServerIdsProvider), isEmpty);
    expect(await search(4), isEmpty);
    expect(client.searches, 5);
    client.searchError = null;
    reachability.record('s', config.clientKey('s'), true);
    await tester.pump(const Duration(milliseconds: 1));
    expect(container.read(availableAggregateServerIdsProvider), {'s'});
  });
}
