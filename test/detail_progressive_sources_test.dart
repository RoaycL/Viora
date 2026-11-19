import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/data/aggregate/sources.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/index/index_sync.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/data/media/server_registry.dart';
import 'package:viora/player/preload.dart';

ServerConfig _server(String id) => ServerConfig(
  id: id,
  type: ServerType.emby,
  name: id,
  username: 'alice',
  userId: 'u-$id',
  token: 'token-$id',
  lines: [ServerLine(id: 'l', name: 'main', url: 'https://$id.example')],
);

MediaItem _movie(String serverId, String id) => MediaItem(
  serverId: serverId,
  id: id,
  kind: MediaKind.movie,
  name: '历史那些事',
  year: 2018,
  tmdbId: '42',
);

/// 假服务器：详情、搜索、播放信息都可以单独控制
class _Client extends EmbyClient {
  _Client(ServerConfig server, AppConfig config) : super(config: config, server: server, appVersion: 'test');

  Future<MediaItem> Function(String id) onItem = (_) => throw const MediaServerException('HTTP 502', statusCode: 502);
  List<MediaItem> found = const [];
  Future<PlaybackInfoResult> Function(String id) onInfo = (_) async => (sources: const [], playSessionId: null);

  @override
  Future<MediaItem> item(String id) => onItem(id);

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
  }) async => PagedItems(found, found.length);

  @override
  Future<PlaybackInfoResult> playbackInfo(String itemId, {bool isPlayback = false}) => onInfo(itemId);
}

PlaybackInfoResult _sources(String serverId, String itemId) => (
  sources: [MediaSourceInfo(serverId: serverId, itemId: itemId, id: 'src-$serverId', container: 'mkv')],
  playSessionId: null,
);

void main() {
  setUp(() {
    PlaybackPreloader.reset();
    ItemSeeds.clear();
    ConfigStore.vault = MemoryVault();
    SharedPreferences.setMockInitialValues({});
  });

  test('当前服务器取详情报 502：用卡片信息继续聚合；各服务器的版本先返回的先显示', () async {
    final a = _server('a'), b = _server('b');
    final config = AppConfig(servers: [a, b]);
    final home = _Client(a, config)..onInfo = (id) async => _sources('a', id);
    final gate = Completer<void>();
    final other = _Client(b, config)
      ..found = [_movie('b', 'm-b')]
      ..onInfo = (id) async {
        await gate.future;
        return _sources('b', id);
      };
    final container = ProviderContainer(
      overrides: [
        serverClientProvider.overrideWith((ref, id) => id == 'a' ? home : other),
        mediaIndexProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    await container.read(configProvider.notifier).update((_) => config);

    ItemSeeds.remember(_movie('a', 'm-a'));
    const key = (serverId: 'a', itemId: 'm-a');
    final partial = container.listen(partialSourcesProvider(itemSourcesKey(key)), (_, _) {});
    final sub = container.listen(sourceOptionsProvider(key), (_, _) {});

    // 另一台还没返回：当前服务器的版本已经可以显示
    for (var i = 0; i < 200 && partial.read() == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(partial.read()?.map((o) => o.serverId), ['a']);
    expect(sub.read().isLoading, isTrue);

    gate.complete();
    final all = await container.read(sourceOptionsProvider(key).future);
    expect(all.map((o) => o.serverId).toSet(), {'a', 'b'});
  });

  test('没有卡片信息时，当前服务器取详情失败照常报错', () async {
    final a = _server('a');
    final config = AppConfig(servers: [a]);
    final home = _Client(a, config);
    final container = ProviderContainer(
      overrides: [
        serverClientProvider.overrideWith((ref, id) => home),
        mediaIndexProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    await container.read(configProvider.notifier).update((_) => config);
    final sub = container.listen(sourceOptionsProvider((serverId: 'a', itemId: 'x')), (_, _) {});
    for (var i = 0; i < 200 && sub.read().isLoading; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(sub.read().error, isA<MediaServerException>());
  });

  test('逐台结果和当前服务器的版本合并：不重复，中间结果在前', () {
    SourceOption option(String serverId) => SourceOption(
      item: _movie(serverId, 'm-$serverId'),
      source: _sources(serverId, 'm-$serverId').sources.single,
      serverName: serverId,
      latencyMs: null,
      account: 'acc',
      view: 'view',
    );
    final a = option('a'), b = option('b');
    expect(mergeSourceOptions(null, [a]), [a]);
    expect(mergeSourceOptions([b], [a, b]), [b, a]);
    expect(mergeSourceOptions(const [], null), isEmpty);
  });

  test('卡片信息：同一条只留最新的，换账号时清空', () {
    ItemSeeds.remember(_movie('a', '1'));
    final newer = MediaItem(serverId: 'a', id: '1', kind: MediaKind.movie, name: 'new');
    ItemSeeds.remember(newer);
    expect(ItemSeeds.of('a', '1')?.name, 'new');
    ItemSeeds.clear();
    expect(ItemSeeds.of('a', '1'), isNull);
  });
}
