import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/data/aggregate/sources.dart';
import 'package:viora/data/aggregate/tmdb_link.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/index/index_sync.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/data/media/server_registry.dart';
import 'package:viora/data/tmdb/tmdb_client.dart';
import 'package:viora/features/detail/episode_catalog.dart';
import 'package:viora/features/detail/item_detail_page.dart';
import 'package:viora/features/tmdb/tmdb_detail_page.dart';
import 'package:viora/player/preload.dart';
import 'package:viora/ui/focus/row_focus.dart';

const home = ServerConfig(
  id: 'home',
  name: 'Home',
  type: ServerType.emby,
  username: 'u',
  userId: 'u',
  token: 't',
  aggregate: false,
  lines: [ServerLine(id: 'l', name: 'l', url: 'https://unused.example')],
);
const other = ServerConfig(
  id: 'other',
  name: 'Other',
  type: ServerType.jellyfin,
  username: 'u',
  userId: 'u',
  token: 't',
  lines: [ServerLine(id: 'l', name: 'l', url: 'https://unused.example')],
);
const title = TmdbTitle(
  id: 42,
  isTv: true,
  title: '剧集',
  seasonList: [
    TmdbSeason(number: 1, name: '第 1 季'),
    TmdbSeason(number: 2, name: '第 2 季'),
  ],
);
const seriesKey = (
  home: (serverId: 'home', itemId: 'show'),
  title: (isTv: true, id: 42, title: '剧集', originalTitle: null, year: null),
);
MediaItem show(String server) =>
    MediaItem(serverId: server, id: 'show', name: '剧集', kind: MediaKind.series, tmdbId: '42');
MediaItem episode(String id, {String server = 'home', int season = 1, int number = 1}) => MediaItem(
  serverId: server,
  id: id,
  name: '服务器 $id',
  kind: MediaKind.episode,
  seriesId: 'show',
  seasonNumber: season,
  episodeNumber: number,
);
final futureEpisodes = [
  TmdbEpisode(season: 1, number: 1, name: '已播集', airDate: DateTime(2020, 1, 1)),
  TmdbEpisode(season: 1, number: 2, name: '超前集', airDate: DateTime(2099, 1, 2)),
  TmdbEpisode(season: 1, number: 3, name: '未来缺集', airDate: DateTime(2099, 1, 3)),
];

class _Config extends ConfigStore {
  @override
  AppConfig build() => const AppConfig(servers: [home, other]);
}

class _Client extends EmbyClient {
  _Client(ServerConfig server, this.list)
    : super(
        config: AppConfig(servers: [server]),
        server: server,
        appVersion: 'test',
      );
  final List<MediaItem> list;
  int episodeRequests = 0;
  final playbackRequests = <String>[];
  @override
  Future<MediaItem> item(String id) async => id == 'show' ? show(server.id) : list.firstWhere((e) => e.id == id);
  @override
  Future<List<MediaItem>> seasons(String id) async => [
    MediaItem(serverId: server.id, id: 's1', name: '第 1 季', kind: MediaKind.season, seasonNumber: 1),
    MediaItem(serverId: server.id, id: 's2', name: '第 2 季', kind: MediaKind.season, seasonNumber: 2),
  ];
  @override
  Future<List<MediaItem>> episodes(String id, {String? seasonId}) async {
    episodeRequests++;
    return seasonId == null ? list : list.where((e) => e.seasonNumber == (seasonId == 's1' ? 1 : 2)).toList();
  }

  @override
  Future<MediaItem?> nextUp(String id) async => list.firstOrNull;
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
  }) async => PagedItems([show(server.id)], 1);
  @override
  Future<PlaybackInfoResult> playbackInfo(String id, {bool isPlayback = false}) async {
    playbackRequests.add(id);
    return (
      sources: [MediaSourceInfo(serverId: server.id, itemId: id, id: 'source-$id', container: 'mkv')],
      playSessionId: null,
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ConfigStore.vault = MemoryVault();
    PlaybackPreloader.reset();
    PlaybackPreloader.enabled = false;
  });
  tearDown(() {
    PlaybackPreloader.enabled = true;
    PlaybackPreloader.reset();
  });

  test('catalog keeps future, unknown dates and server-only episodes without replacing TMDB names', () {
    final entries = mergeEpisodeCatalog(futureEpisodes, [
      episode('renamed'),
      episode('extra', number: 4),
      episode('next-season', season: 2),
    ], 1);
    expect(entries.map((e) => e.number), [1, 2, 3, 4]);
    expect(entries.first.name, '已播集');
    expect(entries[1].upcoming, isTrue);
    expect(entries.last.airDate, isNull);
  });

  test('empty TMDB season falls back to server episodes with dates', () {
    final entry = MediaItem(
      serverId: 'home',
      id: 'extra',
      kind: MediaKind.episode,
      name: '备用标题',
      seasonNumber: 1,
      episodeNumber: 8,
      premiereDate: DateTime(2099, 2, 1),
    );
    final catalog = mergeEpisodeCatalog([], [entry], 1);
    expect(catalog.single.number, 8);
    expect(catalog.single.airDate, DateTime(2099, 2, 1));
  });

  test('TMDB seasons include future seasons, preserve server extras, place specials last', () {
    final catalog = mergeSeasonCatalog(title.seasonList, [
      const MediaItem(serverId: 'home', id: 's0', name: '特别篇', kind: MediaKind.season, seasonNumber: 0),
      const MediaItem(serverId: 'home', id: 's3', name: '额外季', kind: MediaKind.season, seasonNumber: 3),
    ]);
    expect(catalog.map((s) => s.number), [1, 2, 3, 0]);
  });

  test('home source remains included without aggregation; duplicate copies reuse episode requests', () async {
    final a = _Client(home, [episode('e1')]);
    final b = _Client(other, [episode('e2', server: 'other', number: 2)]);
    final container = ProviderContainer(
      overrides: [
        configProvider.overrideWith(_Config.new),
        serverClientProvider.overrideWith((ref, id) => id == 'home' ? a : b),
        tmdbLibrarySearchProvider.overrideWith((ref, key) async => [show('home'), show('other')]),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(librarySeriesEpisodesProvider(seriesKey), (_, _) {});
    final episodes = await container.read(librarySeriesEpisodesProvider(seriesKey).future);
    expect(episodes.map((e) => e.id), ['e1', 'e2']);
    expect(a.episodeRequests, 1);
    expect(b.episodeRequests, 1);
    subscription.close();
  });

  test('specific season/episode can play from another server before air date; missing never uses next-up', () async {
    final a = _Client(home, [episode('s1e1')]);
    final b = _Client(other, [
      episode('s1e2', server: 'other', number: 2),
      episode('s2e2', server: 'other', season: 2, number: 2),
    ]);
    final container = ProviderContainer(
      overrides: [
        configProvider.overrideWith(_Config.new),
        serverClientProvider.overrideWith((ref, id) => id == 'home' ? a : b),
        tmdbLibrarySearchProvider.overrideWith((ref, key) async => [show('other')]),
      ],
    );
    addTearDown(container.dispose);
    final options = await container.read(
      libraryEpisodeSourcesProvider((series: seriesKey, season: 1, episode: 2)).future,
    );
    expect(options.single.item.id, 's1e2');
    expect(options.single.serverId, 'other');
    expect(b.playbackRequests, ['s1e2']);
    expect(a.playbackRequests, isEmpty);
    expect(
      await container.read(libraryEpisodeSourcesProvider((series: seriesKey, season: 1, episode: 3)).future),
      isEmpty,
    );
  });

  testWidgets('selected upcoming episode keeps date/status and remote select remains enabled', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    int? picked;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Material(
            child: RowFocusScope(
              child: SingleChildScrollView(
                child: EpisodeCatalogRow(
                  tvId: 42,
                  season: 1,
                  episodes: futureEpisodes,
                  selected: 2,
                  library: [episode('advance', number: 2)],
                  libraryLoaded: true,
                  onSelect: (number) => picked = number,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未播出 · 已入库'), findsOneWidget);
    expect(find.textContaining('2099-01-02'), findsOneWidget);
    final row = tester.element(find.byType(EpisodeCatalogRow));
    RowFocusScope.of(row).focusRow(2, index: 1);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, 2);
    expect(tester.takeException(), isNull);
  });

  Future<void> pumpDetail(
    WidgetTester tester, {
    bool tmdb = true,
    bool seasonFails = false,
    bool tmdbEntry = false,
    bool withSecondSeason = false,
    Future<List<MediaItem>>? otherServers,
  }) async {
    tester.view.physicalSize = const Size(1920, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final a = _Client(home, [episode('home-first'), if (withSecondSeason) episode('old-season2', season: 2)]);
    final bob = _Client(home.copyWith(username: 'bob', userId: 'bob'), [episode('bob-first')]);
    final b = _Client(other, [episode('advance', server: 'other', number: 2)]);
    final router = GoRouter(
      initialLocation: '/item',
      routes: [
        GoRoute(
          path: '/item',
          builder: (_, _) => tmdbEntry
              ? const TmdbDetailPage(isTv: true, id: 42)
              : const ItemDetailPage(serverId: 'home', itemId: 'show'),
        ),
        GoRoute(path: '/play/:server/:item', builder: (_, state) => Text('playing ${state.pathParameters['item']}')),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configProvider.overrideWith(_Config.new),
          serverClientProvider.overrideWith(
            (ref, id) => id == 'home' ? (ref.watch(configProvider).server(id)?.userId == 'bob' ? bob : a) : b,
          ),
          tmdbTitleProvider.overrideWith((ref, key) async => tmdb ? title : null),
          tmdbSeasonProvider.overrideWith((ref, key) async {
            if (seasonFails) throw StateError('offline');
            return key.season == 1 ? futureEpisodes : [const TmdbEpisode(season: 2, number: 1, name: '第二季')];
          }),
          tmdbLibrarySearchProvider.overrideWith((ref, key) => otherServers ?? Future.value([show('other')])),
          mediaIndexProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('library detail selects unavailable future episode without playing the next-up instead', (tester) async {
    await pumpDetail(tester);
    expect(find.byType(EpisodeCatalogRow), findsOneWidget);
    final card = find.byKey(const ValueKey('episode-1-3'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.text('暂无 S1E3 资源'), findsOneWidget);
    expect(find.text('暂未找到第 1 季第 3 集的播放资源'), findsOneWidget);
    expect(find.textContaining('playing'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('library detail can play the home copy before slow servers finish searching', (tester) async {
    final slow = Completer<List<MediaItem>>();
    await pumpDetail(tester, otherServers: slow.future);
    // 其他服务器还在搜索：当前服务器的第 1 集已经可以播放，不显示「正在查找」
    expect(find.text('播放 S1E1'), findsOneWidget);
    expect(find.textContaining('正在查找'), findsNothing);
    slow.complete([show('other')]);
    await tester.pumpAndSettle();
    expect(find.text('播放 S1E1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('library detail plays a selected advance episode on its actual server', (tester) async {
    await pumpDetail(tester);
    final card = find.byKey(const ValueKey('episode-1-2'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.text('播放 S1E2'), findsOneWidget);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.text('playing advance'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching to a future season clears the previous episode resource selection', (tester) async {
    await pumpDetail(tester);
    final season = find.text('第 2 季');
    await tester.ensureVisible(season);
    await tester.pumpAndSettle();
    await tester.tap(season);
    await tester.pumpAndSettle();
    expect(find.text('1. 第二季'), findsOneWidget);
    expect(find.text('暂无 S2E1 资源'), findsOneWidget);
    expect(find.text('播放 S1E1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TMDB entry also plays an upcoming episode and keeps the air date visible', (tester) async {
    await pumpDetail(tester, tmdbEntry: true);
    final card = find.byKey(const ValueKey('episode-1-2'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.textContaining('2099-01-02'), findsOneWidget);
    expect(find.text('未播出 · 已入库'), findsOneWidget);
    expect(find.text('播放 S1E2'), findsOneWidget);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.text('playing advance'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching accounts resets the selected season and rejects old resources', (tester) async {
    await pumpDetail(tester, withSecondSeason: true);
    final season = find.text('第 2 季');
    await tester.ensureVisible(season);
    await tester.pumpAndSettle();
    await tester.tap(season);
    await tester.pumpAndSettle();
    expect(find.text('播放 S2E1'), findsOneWidget);
    final context = tester.element(find.byType(ItemDetailPage));
    final container = ProviderScope.containerOf(context);
    await container
        .read(configProvider.notifier)
        .updateServer('home', (server) => server.copyWith(username: 'bob', userId: 'bob'));
    await tester.pumpAndSettle();
    expect(find.text('播放 S1E1'), findsOneWidget);
    expect(find.text('播放 S2E1'), findsNothing);
    final row = tester.widget<EpisodeCatalogRow>(find.byType(EpisodeCatalogRow));
    expect(row.season, 1);
    expect(row.library.where((episode) => episode.serverId == 'home').single.id, 'bob-first');
    expect(tester.takeException(), isNull);
  });

  testWidgets('TMDB unavailable preserves ordinary server season/episode controls', (tester) async {
    await pumpDetail(tester, tmdb: false);
    expect(find.byType(EpisodeCatalogRow), findsNothing);
    expect(find.text('服务器 home-first'), findsWidgets);
    expect(find.text('播放 S1E1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TMDB season request failure still exposes the server episode', (tester) async {
    await pumpDetail(tester, seasonFails: true);
    expect(find.byType(EpisodeCatalogRow), findsOneWidget);
    expect(find.text('1. 服务器 home-first'), findsOneWidget);
    expect(find.text('播放 S1E1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
