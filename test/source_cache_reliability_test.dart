import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/core/log/app_log.dart';
import 'package:viora/data/aggregate/sources.dart';
import 'package:viora/core/log/load_metrics.dart';
import 'package:viora/data/cache/account_scope.dart';
import 'package:viora/data/cache/snapshot_cache.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/history/play_history.dart';
import 'package:viora/data/index/media_index.dart';
import 'package:viora/data/index/index_sync.dart';
import 'package:viora/data/media/media_feed.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/data/media/server_registry.dart';
import 'package:viora/player/preload.dart';

const server = ServerConfig(
  id: 's',
  type: ServerType.emby,
  name: 'home',
  username: 'alice',
  userId: 'u1',
  token: 'private-token',
  password: 'private-password',
  lines: [ServerLine(id: 'l', name: 'main', url: 'https://private-host.example')],
);
MediaItem movie(String id, {String serverId = 's'}) =>
    MediaItem(serverId: serverId, id: id, kind: MediaKind.movie, name: 'Movie $id');

class FeedClient extends EmbyClient {
  FeedClient(ServerConfig server)
    : super(
        config: AppConfig(servers: [server]),
        server: server,
        appVersion: 'test',
      );
  final starts = <int>[];
  final limits = <int>[];
  late Future<PagedItems> Function(int start) page;
  Future<List<MediaItem>> Function()? resumeAction;
  Future<PlaybackInfoResult> Function()? infoAction;

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
  }) {
    starts.add(start);
    limits.add(limit);
    return page(start);
  }

  @override
  Future<List<MediaItem>> resume({int limit = 12}) => resumeAction!();
  @override
  Future<PlaybackInfoResult> playbackInfo(String itemId, {bool isPlayback = false}) => infoAction!();
}

Future<void> until(bool Function() predicate) async {
  for (var i = 0; i < 200 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(predicate(), isTrue);
}

void main() {
  late Directory directory;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('viora-source-test');
    SnapshotCache.resetForTest();
    SnapshotCache.directoryForTest = directory;
    PlaybackPreloader.reset();
    ConfigStore.vault = MemoryVault();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    await SnapshotCache.clear();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  SnapshotSource<List<int>> source(String id, Future<SnapshotFetch<List<int>>> Function() fetch) =>
      SnapshotSource(key: id, id: id, fetch: fetch, encode: (v) => v, decode: (j) => (j as List).cast<int>());
  Future<void> seed(String id, List<int> data) =>
      SnapshotCache.write(id, {'version': 2, 'at': '2026-10-13T00:00:00Z', 'data': data});

  test('one offline source retains its snapshot; successful empty clears only its source', () async {
    await seed('a', [1]);
    await seed('b', [2]);
    final gate = Completer<void>();
    final p = FutureProvider<SnapshotBatch<List<int>>>(
      (ref) => sourceSnapshotsFirst(
        ref,
        'both',
        operation: 'test',
        sources: [
          source('a', () async {
            await gate.future;
            return const SnapshotFetch([]);
          }),
          source('b', () async {
            await gate.future;
            throw const SocketException('offline');
          }),
        ],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final sub = container.listen(p, (_, _) {});
    expect((await container.read(p.future)).sources.map((s) => s.value), [
      [1],
      [2],
    ]);
    gate.complete();
    await until(() => sub.read().value?.failures == 1);
    final result = sub.read().value!;
    expect(result.sources[0].value, isEmpty);
    expect(result.sources[0].status, SnapshotStatus.fresh);
    expect(result.sources[1].value, [2]);
    expect(result.sources[1].status, SnapshotStatus.failed);
    expect((await SnapshotCache.read('a') as Map)['data'], isEmpty);
    expect((await SnapshotCache.read('b') as Map)['data'], [2]);
  });

  test('incomplete response preserves old disk and UI; no cache remains distinguishable', () async {
    await seed('a', [1, 2]);
    final p = FutureProvider<SnapshotBatch<List<int>>>(
      (ref) => sourceSnapshotsFirst(
        ref,
        'partial',
        operation: 'test',
        sources: [
          source('a', () async => const SnapshotFetch([3], complete: false)),
          source('missing', () async => throw const SocketException('offline')),
        ],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final sub = container.listen(p, (_, _) {});
    await container.read(p.future);
    await until(() => sub.read().value?.failures == 2);
    expect(sub.read().value!.sources.first.value, [1, 2]);
    expect(sub.read().value!.sources.last.value, isNull);
    expect((await SnapshotCache.read('a') as Map)['data'], [1, 2]);
    expect(await SnapshotCache.read('missing'), isNull);
  });

  test('new owner prevents retired response from overwriting the same source', () async {
    final old = Completer<SnapshotFetch<List<int>>>();
    final oldProvider = FutureProvider<SnapshotBatch<List<int>>>(
      (ref) => sourceSnapshotsFirst(ref, 'old', operation: 'test', sources: [source('shared', () => old.future)]),
    );
    final nextProvider = FutureProvider<SnapshotBatch<List<int>>>(
      (ref) => sourceSnapshotsFirst(
        ref,
        'next',
        operation: 'test',
        sources: [
          source('shared', () async => const SnapshotFetch([2])),
        ],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final oldFuture = container.read(oldProvider.future);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await container.read(nextProvider.future);
    old.complete(const SnapshotFetch([1]));
    await oldFuture;
    expect((await SnapshotCache.read('shared') as Map)['data'], [2]);
  });

  test('serialized writes and clear do not resurrect stale files', () async {
    await Future.wait([
      SnapshotCache.write('same', [1]),
      SnapshotCache.write('same', [2]),
    ]);
    expect(await SnapshotCache.read('same'), [2]);
    final pending = SnapshotCache.write('same', [3]);
    await SnapshotCache.clear();
    await pending;
    expect(File('${directory.path}/same.json').existsSync(), isFalse);
  });

  test('favorites fetch all pages and advance by raw count after rating filtering', () async {
    final client = FeedClient(server)
      ..page = (start) async => switch (start) {
        0 => PagedItems([for (var i = 0; i < 150; i++) movie('$i')], 250, rawCount: 200),
        200 => PagedItems([for (var i = 200; i < 250; i++) movie('$i')], 250, rawCount: 50),
        _ => throw StateError('unexpected offset'),
      };
    final result = await fetchFavoritePages(client);
    expect(client.starts, [0, 200]);
    expect(result.complete, isTrue);
    expect(result.value.length, 200);
  });

  test('unknown total and server page cap continue until empty', () async {
    final client = FeedClient(server)
      ..page = (start) async =>
          PagedItems(start < 6 ? [movie('$start'), movie('${start + 1}')] : [], 2, totalKnown: false);
    final result = await fetchFavoritePages(client);
    expect(client.starts, [0, 2, 4, 6]);
    expect(result.value.length, 6);
    expect(result.complete, isTrue);
  });

  test('duplicate page, changing total and premature empty are incomplete', () async {
    for (var mode = 0; mode < 3; mode++) {
      final client = FeedClient(server)
        ..page = (start) async => start == 0
            ? PagedItems([movie('a')], 2)
            : mode == 0
            ? PagedItems([movie('a')], 2)
            : mode == 1
            ? PagedItems([movie('b')], 3)
            : const PagedItems([], 2);
      expect((await fetchFavoritePages(client)).complete, isFalse);
    }
  });

  test('failure after first favorite page propagates instead of becoming empty success', () async {
    final client = FeedClient(server)
      ..page = (start) async {
        if (start > 0) throw const SocketException('offline');
        return PagedItems([movie('a')], 2);
      };
    await expectLater(fetchFavoritePages(client), throwsA(isA<SocketException>()));
  });

  test('actual client rejects missing lists and records raw count before parental filtering', () async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => http.close(force: true));
    Object response = {'Items': [], 'TotalRecordCount': 0};
    var status = 200;
    http.listen((request) async {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
    final local = server.copyWith(
      lines: [ServerLine(id: 'l', name: 'local', url: 'http://127.0.0.1:${http.port}')],
    );
    final client = EmbyClient(
      config: AppConfig(servers: [local], parental: const ParentalConfig(enabled: true)),
      server: local,
      appVersion: 'test',
    );
    expect((await client.items()).receivedCount, 0);
    expect(await client.resume(), isEmpty);
    response = {
      'Items': [
        {'Id': 'r', 'Type': 'Movie', 'Name': 'Restricted', 'OfficialRating': 'R'},
      ],
      'TotalRecordCount': 1,
    };
    final filtered = await client.items();
    expect(filtered.items, isEmpty);
    expect(filtered.receivedCount, 1);
    response = {'Message': 'malformed success'};
    await expectLater(client.items(), throwsA(isA<MediaServerException>()));
    await expectLater(client.resume(), throwsA(isA<MediaServerException>()));
    response = {'Items': [], 'TotalRecordCount': 3};
    expect((await fetchMediaFeed(client, MediaFeedKind.recentlyPlayed)).complete, isFalse);
    await expectLater(client.resume(), throwsA(isA<MediaServerException>()));
    status = 403;
    await expectLater(client.resume(), throwsA(isA<MediaServerException>()));
    final marker = 'op=media_api phase=remote source=${accountScope(local).substring(0, 10)} outcome=failed';
    expect(AppLog.dump(appVersion: 'test'), contains(marker));
  });

  test('account identity ignores tokens and lines but isolates user and parental view', () {
    expect(accountScope(server.copyWith(token: 'new', password: 'new', name: 'renamed')), accountScope(server));
    expect(accountScope(server.copyWith(userId: 'u2')), isNot(accountScope(server)));
    // 改线路地址 / 加线路不算换账号（换到另一台服务器时，重新登录拿到的用户 ID 不同，仍会隔离）
    expect(
      accountScope(server.copyWith(lines: [server.lines.single.copyWith(url: 'https://other.example')])),
      accountScope(server),
    );
    expect(
      mediaFeedScope(AppConfig(servers: [server])),
      isNot(mediaFeedScope(AppConfig(servers: [server.copyWith(clearSession: true)]))),
    );
    expect(
      mediaViewScope(const AppConfig()),
      isNot(mediaViewScope(const AppConfig(parental: ParentalConfig(enabled: true)))),
    );
    expect(
      mediaFeedScope(AppConfig(servers: [server.copyWith(adult: true)], parental: const ParentalConfig(enabled: true))),
      mediaFeedScope(const AppConfig(parental: ParentalConfig(enabled: true))),
    );
  });

  test('account switch shows no previous feed while next account is delayed', () async {
    final second = server.copyWith(username: 'bob', userId: 'u2');
    final oldClient = FeedClient(server)..resumeAction = () async => [movie('old')];
    final gate = Completer<List<MediaItem>>();
    final newClient = FeedClient(second)..resumeAction = () => gate.future;
    final container = ProviderContainer(
      overrides: [
        serverClientProvider.overrideWith(
          (ref, id) => ref.watch(configProvider).server(id)?.userId == 'u1' ? oldClient : newClient,
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(configProvider.notifier).update((c) => AppConfig(servers: [server]));
    final sub = container.listen(mediaFeedStateProvider(MediaFeedKind.resume), (_, _) {});
    await until(() => sub.read().value != null);
    expect(sub.read().value!.items.single.id, 'old');
    await container.read(configProvider.notifier).update((c) => AppConfig(servers: [second]));
    expect(sub.read().isLoading, isTrue);
    expect(sub.read().value, isNull);
    gate.complete([movie('new')]);
    await until(() => sub.read().value != null);
    expect(sub.read().value!.items.single.id, 'new');
    await container.read(configProvider.notifier).update((c) => const AppConfig());
    await until(() => sub.read().value != null);
    expect(sub.read().value!.items, isEmpty);
  });

  test('late login callback cannot replace the configured new account', () async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => http.close(force: true));
    final received = Completer<void>();
    final respond = Completer<void>();
    http.listen((request) async {
      received.complete();
      await respond.future;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'AccessToken': 'old-renewed',
          'User': {'Id': 'u1'},
        }),
      );
      await request.response.close();
    });
    final local = server.copyWith(
      lines: [ServerLine(id: 'l', name: 'local', url: 'http://127.0.0.1:${http.port}')],
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(configProvider.notifier).update((c) => AppConfig(servers: [local]));
    final oldClient = container.read(serverClientProvider('s'))!;
    final pending = oldClient.login();
    await received.future;
    await container
        .read(configProvider.notifier)
        .update(
          (c) => AppConfig(
            servers: [local.copyWith(username: 'bob', userId: 'u2', token: 'bob-token')],
          ),
        );
    respond.complete();
    await pending;
    expect(container.read(configProvider).server('s')!.userId, 'u2');
    expect(container.read(configProvider).server('s')!.token, 'bob-token');
  });

  test('same-account cached sources survive refresh; changed account and restrictions hide them', () {
    final config = AppConfig(servers: [server]);
    final option = SourceOption(
      item: movie('same'),
      source: const MediaSourceInfo(serverId: 's', itemId: 'same', id: 'v', container: 'mkv'),
      serverName: 'home',
      account: accountScope(server),
      view: mediaViewScope(config),
    );
    expect(visibleSourceOptions(config, [option]), [option]);
    expect(visibleSourceOptions(AppConfig(servers: [server.copyWith(token: 'renewed')]), [option]), [option]);
    expect(visibleSourceOptions(AppConfig(servers: [server.copyWith(userId: 'u2')]), [option]), isEmpty);
    expect(visibleSourceOptions(config.copyWith(parental: const ParentalConfig(enabled: true)), [option]), isEmpty);
    expect(visibleSourceOptions(const AppConfig(), [option]), isEmpty);
  });

  test('retired index sync cannot write or replace the new account status', () async {
    final next = server.copyWith(userId: 'u2', username: 'bob');
    final gate = Completer<PagedItems>();
    final a = FeedClient(server)..page = (_) => gate.future;
    final b = FeedClient(next)..page = (_) async => PagedItems([movie('bob')], 1);
    final container = ProviderContainer(
      overrides: [
        serverClientProvider.overrideWith((ref, id) => ref.watch(configProvider).server(id)?.userId == 'u1' ? a : b),
        mediaIndexProvider.overrideWith((ref) async {
          ref.watch(configProvider.select(indexAccountsKey));
          final index = (await MediaIndex.open(path: ':memory:'))!;
          index.bindAccounts(indexAccountScopes(ref.read(configProvider)));
          ref.onDispose(index.close);
          return index;
        }),
      ],
    );
    addTearDown(container.dispose);
    await container.read(configProvider.notifier).update((c) => AppConfig(servers: [server]));
    final sync = container.read(indexSyncProvider.notifier);
    final retired = sync.syncServer('s');
    await until(() => a.starts.isNotEmpty);
    await container.read(configProvider.notifier).update((c) => AppConfig(servers: [next]));
    await sync.syncServer('s');
    gate.complete(PagedItems([movie('alice')], 1));
    await retired;
    final index = await container.read(mediaIndexProvider.future);
    expect(index!.count('s'), 1);
    expect(index.search('alice'), isEmpty);
    expect(index.search('bob').single.id, 'bob');
    expect(container.read(indexSyncProvider)['s']!.count, 1);
    expect(container.read(indexSyncProvider)['s']!.running, isFalse);
  });

  test('premature empty index page never commits deletion of old rows', () async {
    final index = (await MediaIndex.open(path: ':memory:'))!;
    addTearDown(index.close);
    index.bindAccounts({'s': accountScope(server)});
    index.upsert('s', [movie('keep')]);
    final client = FeedClient(server)..page = (_) async => const PagedItems([], 3);
    final container = ProviderContainer(
      overrides: [
        mediaIndexProvider.overrideWith((ref) async => index),
        serverClientProvider.overrideWith((ref, id) => client),
      ],
    );
    addTearDown(container.dispose);
    await container.read(configProvider.notifier).update((c) => AppConfig(servers: [server]));
    await container.read(indexSyncProvider.notifier).syncServer('s', forceFull: true);
    expect(index.count('s'), 1);
    expect(index.search('keep').single.id, 'keep');
    expect(index.syncState('s').fullAt, isNull);
    expect(container.read(indexSyncProvider)['s']!.error, isNotNull);
  });

  test('full index sync continues when new items are added on the server mid-sync', () async {
    final index = (await MediaIndex.open(path: ':memory:'))!;
    addTearDown(index.close);
    index.bindAccounts({'s': accountScope(server)});
    // 第一页时服务器共 201 部；同步过程中又入库一部，第二页时总数变成 202（新条目按入库时间排在最后）
    final client = FeedClient(server)
      ..page = (start) async => start == 0
          ? PagedItems([for (var i = 0; i < 200; i++) movie('m$i')], 201)
          : PagedItems([movie('m200'), movie('m201')], 202);
    final container = ProviderContainer(
      overrides: [
        mediaIndexProvider.overrideWith((ref) async => index),
        serverClientProvider.overrideWith((ref, id) => client),
      ],
    );
    addTearDown(container.dispose);
    await container.read(configProvider.notifier).update((c) => AppConfig(servers: [server]));
    await container.read(indexSyncProvider.notifier).syncServer('s', forceFull: true);
    expect(container.read(indexSyncProvider)['s']!.error, isNull);
    expect(index.count('s'), 202);
    expect(index.syncState('s').fullAt, isNotNull);
  });

  test('一次取太多条时服务器报 HTTP 500：每页减半从同一位置重试，同步照常完成', () async {
    final index = (await MediaIndex.open(path: ':memory:'))!;
    addTearDown(index.close);
    index.bindAccounts({'s': accountScope(server)});
    late FeedClient client;
    client = FeedClient(server)
      ..page = (start) async {
        if (client.limits.last > 100) throw const MediaServerException('服务器返回 HTTP 500', statusCode: 500);
        final end = (start + client.limits.last).clamp(0, 150);
        return PagedItems([for (var i = start; i < end; i++) movie('m$i')], 150);
      };
    final container = ProviderContainer(
      overrides: [
        mediaIndexProvider.overrideWith((ref) async => index),
        serverClientProvider.overrideWith((ref, id) => client),
      ],
    );
    addTearDown(container.dispose);
    await container.read(configProvider.notifier).update((c) => AppConfig(servers: [server]));
    await container.read(indexSyncProvider.notifier).syncServer('s', forceFull: true);
    expect(container.read(indexSyncProvider)['s']!.error, isNull);
    expect(index.count('s'), 150);
    expect(client.limits, [200, 100, 100]);
    expect(client.starts, [0, 0, 100]);
    // 本次运行里记住：下次同步直接用 100
    await container.read(indexSyncProvider.notifier).syncServer('s');
    expect(client.limits.sublist(3).every((l) => l == 100), isTrue);
  });

  test('关掉本地索引的服务器不同步，账号也不绑定到索引', () async {
    final index = (await MediaIndex.open(path: ':memory:'))!;
    addTearDown(index.close);
    final off = server.copyWith(indexEnabled: false);
    final config = AppConfig(servers: [off]);
    expect(indexAccountScopes(config), isEmpty);
    expect(ServerConfig.fromJson(off.toJson()).indexEnabled, isFalse);
    expect(ServerConfig.fromJson({...server.toJson()}..remove('index')).indexEnabled, isTrue);
    final client = FeedClient(off)..page = (_) async => PagedItems([movie('m')], 1);
    final container = ProviderContainer(
      overrides: [
        mediaIndexProvider.overrideWith((ref) async => index),
        serverClientProvider.overrideWith((ref, id) => client),
      ],
    );
    addTearDown(container.dispose);
    await container.read(configProvider.notifier).update((c) => config);
    await container.read(indexSyncProvider.notifier).syncAll();
    await container.read(indexSyncProvider.notifier).syncServer('s', forceFull: true);
    expect(client.starts, isEmpty);
  });

  test('full index sync still aborts when the server total shrinks mid-sync', () async {
    final index = (await MediaIndex.open(path: ':memory:'))!;
    addTearDown(index.close);
    index.bindAccounts({'s': accountScope(server)});
    index.upsert('s', [movie('keep')]);
    final client = FeedClient(server)
      ..page = (start) async =>
          start == 0 ? PagedItems([for (var i = 0; i < 200; i++) movie('m$i')], 202) : PagedItems([movie('m200')], 201);
    final container = ProviderContainer(
      overrides: [
        mediaIndexProvider.overrideWith((ref) async => index),
        serverClientProvider.overrideWith((ref, id) => client),
      ],
    );
    addTearDown(container.dispose);
    await container.read(configProvider.notifier).update((c) => AppConfig(servers: [server]));
    await container.read(indexSyncProvider.notifier).syncServer('s', forceFull: true);
    expect(container.read(indexSyncProvider)['s']!.error, isNotNull);
    expect(index.syncState('s').fullAt, isNull);
    expect(index.search('keep').single.id, 'keep');
  });

  test('upgrading from the line-based identity keeps the index and local watch history', () async {
    final index = (await MediaIndex.open(path: ':memory:'))!;
    addTearDown(index.close);
    index.bindAccounts({'s': legacyAccountScope(server)});
    index.upsert('s', [movie('keep')]);
    index.bindAccounts({'s': accountScope(server)}, legacy: {'s': legacyAccountScope(server)});
    expect(index.search('keep').single.id, 'keep');
    expect(index.hasAccount('s', accountScope(server)), isTrue);
    // 之后真正换账号仍然清空
    index.bindAccounts({'s': 'someone-else'});
    expect(index.count('s'), 0);

    SharedPreferences.setMockInitialValues({
      'viora.playHistory.v1': '{"v2/${legacyAccountScope(server)}/ep1": 1700000000000}',
    });
    await PlayHistory.load();
    PlayHistory.bindAccount('s', accountScope(server), legacy: legacyAccountScope(server));
    expect(PlayHistory.lastPlayed(movie('ep1')), DateTime.fromMillisecondsSinceEpoch(1700000000000));
  });

  test('index migrates unscoped rows and clears only changed or removed accounts', () async {
    final index = (await MediaIndex.open(path: ':memory:'))!;
    addTearDown(index.close);
    index.upsert('s', [movie('legacy')]);
    index.beginFull('emptyLegacy');
    index.bindAccounts({'s': 'alice', 'b': 'bob'});
    expect(index.count('s'), 0);
    expect(index.syncState('emptyLegacy').gen, 0);
    index.upsert('s', [movie('alice')]);
    index.upsert('b', [movie('bob', serverId: 'b')]);
    index.bindAccounts({'s': 'alice', 'b': 'bob'});
    expect(index.count('s'), 1);
    index.bindAccounts({'s': 'charlie', 'b': 'bob'});
    expect(index.count('s'), 0);
    expect(index.count('b'), 1);
    expect(index.hasAccount('s', 'alice'), isFalse);
    index.bindAccounts({'s': 'charlie'});
    expect(index.count('b'), 0);
    index.close();
    expect(index.hasAccount('s', 'charlie'), isFalse);
  });

  test('index JSON preserves official rating', () {
    final item = MediaItem(serverId: 's', id: 'rating', name: 'R', kind: MediaKind.movie, officialRating: 'R');
    expect(MediaItem.fromIndexJson('s', 'rating', item.toIndexJson()).officialRating, 'R');
  });

  test('playback info and late completions are isolated by account and reset', () async {
    final old = Completer<PlaybackInfoResult>();
    final a = FeedClient(server)..infoAction = () => old.future;
    final b = FeedClient(server.copyWith(userId: 'u2'))
      ..infoAction = () async => (sources: <MediaSourceInfo>[], playSessionId: 'bob');
    final pending = PlaybackPreloader.info(a, 's', 'same');
    expect((await PlaybackPreloader.info(b, 's', 'same')).playSessionId, 'bob');
    old.complete((sources: <MediaSourceInfo>[], playSessionId: 'alice'));
    await pending;
    expect((await PlaybackPreloader.info(b, 's', 'same')).playSessionId, 'bob');
    final late = Completer<PlaybackInfoResult>();
    a.infoAction = () => late.future;
    final retired = PlaybackPreloader.info(a, 's', 'reset');
    PlaybackPreloader.reset();
    late.complete((sources: <MediaSourceInfo>[], playSessionId: 'retired'));
    await retired;
    expect(PlaybackPreloader.cached('s', 'reset', scope: accountScope(server)), isNull);
  });

  test('local playback time ignores legacy IDs and old player account completion', () async {
    SharedPreferences.setMockInitialValues({
      'viora.playHistory.v1': jsonEncode({'s/same': 123}),
    });
    await PlayHistory.load();
    PlayHistory.bindAccount('s', 'alice');
    expect(PlayHistory.lastPlayed(movie('same')), isNull);
    await PlayHistory.record('s', 'same');
    expect(PlayHistory.lastPlayed(movie('same')), isNotNull);
    PlayHistory.bindAccount('s', 'bob');
    expect(PlayHistory.lastPlayed(movie('same')), isNull);
    await PlayHistory.record('s', 'same', scope: 'alice');
    expect(PlayHistory.lastPlayed(movie('same')), isNull);
  });

  test('baseline logs include durations, concurrency and outcomes without credentials', () async {
    final trace = LoadTrace('baseline_test');
    trace.event('local_ready', count: 2);
    await LoadTrace.request('baseline_test', accountScope(server).substring(0, 10), () async => 1);
    // 快速成功的请求不逐条记录，免得挤掉闪退前的关键日志；失败的照记
    expect(AppLog.dump(appVersion: 'test'), isNot(contains('op=baseline_test phase=remote')));
    await LoadTrace.request(
      'baseline_test',
      accountScope(server).substring(0, 10),
      () async => 1,
      isSuccess: (_) => false,
    );
    final logs = AppLog.dump(appVersion: 'test');
    expect(logs, contains('phase=local_ready'));
    expect(logs, contains('outcome=failed'));
    expect(logs, contains('active=0 peak=1'));
    expect(logs, isNot(contains('private-token')));
    expect(logs, isNot(contains('private-host.example')));
  });
}
