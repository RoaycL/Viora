import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/app.dart';
import 'package:viora/app/platform_profile.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/data/cache/snapshot_cache.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/data/media/server_registry.dart';
import 'package:viora/data/tmdb/tmdb_client.dart';
import 'package:viora/ui/rows/cards.dart';

List<TmdbTitle> titles(TmdbRow row, {int count = 30}) => [
  for (var i = 0; i < count; i++)
    TmdbTitle(
      id: row.index * 1000 + i,
      isTv: true,
      title: '${row.name}-$i',
      backdropPath: row == TmdbRow.trendingDay ? '/hero-$i.jpg' : null,
    ),
];

Future<void> pumpHome(
  WidgetTester tester, {
  FutureOr<List<TmdbTitle>> Function(TmdbRow)? fetch,
  Map<TmdbRow, int>? requests,
  VoidCallback? people,
  List<Override> overrides = const [],
  TmdbClient? client,
  PlatformProfile profile = PlatformProfile.tv,
  Size viewport = const Size(1920, 1080),
}) async {
  PlatformProfile.debugOverride = profile;
  autoCheckUpdatesOnLaunch = false;
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...overrides,
        tmdbClientProvider.overrideWithValue(
          client ?? TmdbClient(const TmdbConfig(apiKey: 'fixture'), const ProxyConfig()),
        ),
        tmdbRowProvider.overrideWith((ref, row) {
          requests?.update(row, (n) => n + 1, ifAbsent: () => 1);
          return fetch == null ? titles(row) : fetch(row);
        }),
        tmdbPeopleProvider.overrideWith((ref) async {
          people?.call();
          return const <TmdbPerson>[];
        }),
        tmdbTitleProvider.overrideWith((ref, key) async => TmdbTitle(id: key.id, isTv: key.isTv, title: '作品${key.id}')),
      ],
      child: const VioraApp(),
    ),
  );
  await tester.pumpAndSettle();
}

String? get focused => FocusManager.instance.primaryFocus?.debugLabel;

Future<void> press(WidgetTester tester, LogicalKeyboardKey key, {int repeats = 0}) async {
  await tester.sendKeyDownEvent(key);
  for (var i = 0; i < repeats; i++) {
    await tester.sendKeyRepeatEvent(key);
  }
  await tester.sendKeyUpEvent(key);
  await tester.pumpAndSettle();
}

ScrollController verticalController(WidgetTester tester) => tester
    .widget<ListView>(find.byWidgetPredicate((w) => w is ListView && w.scrollDirection == Axis.vertical).first)
    .controller!;

Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

class FailingRecommendations extends TmdbClient {
  FailingRecommendations() : super(const TmdbConfig(apiKey: 'fixture'), const ProxyConfig());
  @override
  Future<List<TmdbTitle>> row(TmdbRow row) async => throw StateError('offline');
  @override
  Future<List<TmdbPerson>> popularPeople() async => throw StateError('offline');
}

class RecordingImages extends TmdbClient {
  RecordingImages() : super(const TmdbConfig(apiKey: 'fixture'), const ProxyConfig());
  final requested = <({String path, String size})>[];
  @override
  String image(String path, {String size = 'w500'}) {
    requested.add((path: path, size: size));
    return super.image(path, size: size);
  }
}

class ResumeFixture extends Notifier<List<MediaItem>> {
  @override
  List<MediaItem> build() => const [MediaItem(serverId: 's', id: 'resume', kind: MediaKind.movie, name: '续播电影')];
  void clear() => state = [];
}

final resumeFixture = NotifierProvider<ResumeFixture, List<MediaItem>>(ResumeFixture.new);

class HomeConfig extends ConfigStore {
  @override
  AppConfig build() => const AppConfig(
    playback: PlaybackConfig(preload: false),
    servers: [ServerConfig(id: 's', name: 'fixture', username: 'fixture', type: ServerType.emby, lines: [])],
  );
}

void main() {
  tearDown(() => PlatformProfile.debugOverride = PlatformProfile.desktop);

  test('推荐请求失败保留错误，不能伪装成成功空列表', () async {
    final container = ProviderContainer(overrides: [tmdbClientProvider.overrideWithValue(FailingRecommendations())]);
    addTearDown(container.dispose);
    await expectLater(container.read(tmdbRowProvider(TmdbRow.nowPlaying).future), throwsStateError);
    await expectLater(container.read(tmdbPeopleProvider.future), throwsStateError);
  });

  testWidgets('数据提前准备，远端卡片仍不挂载，首屏海报数量有界', (tester) async {
    final requests = <TmdbRow, int>{};
    var people = 0;
    await pumpHome(tester, requests: requests, people: () => people++);
    expect(requests.keys, unorderedEquals(TmdbRow.values));
    expect(requests.values, everyElement(1));
    expect(people, 1);
    expect(find.byType(PosterCard).evaluate().length, lessThan(20));
    expect(find.text('高分剧集'), findsNothing);
    expect(focused, 'hero#0');
    await unmount(tester);
  });

  testWidgets('下一行仍在屏外时已请求数据，等到结果后下翻不再经历列表加载', (tester) async {
    final loading = Completer<List<TmdbTitle>>();
    final requests = <TmdbRow, int>{};
    await pumpHome(tester, requests: requests, fetch: (r) => r == TmdbRow.onTheAir ? loading.future : titles(r));
    expect(find.text('正在播出'), findsNothing);
    expect(requests[TmdbRow.onTheAir], 1);
    loading.complete(titles(TmdbRow.onTheAir));
    await tester.pumpAndSettle();
    expect(find.text('onTheAir-0'), findsNothing);
    await press(tester, LogicalKeyboardKey.arrowDown, repeats: 1);
    expect(focused, 'row4#0');
    expect(requests[TmdbRow.onTheAir], 1);
    await unmount(tester);
  });

  testWidgets('两个慢预取不能阻塞直接翻到远端行', (tester) async {
    final slow = Completer<List<TmdbTitle>>();
    final requests = <TmdbRow, int>{};
    await pumpHome(
      tester,
      requests: requests,
      fetch: (r) => r == TmdbRow.nowPlaying || r == TmdbRow.onTheAir ? slow.future : titles(r),
    );
    // 两个慢预取占满后台队列；只有挂载范围内（视口外约两行）的行自己发起请求，远端行还没请求
    expect(requests.keys, containsAll([TmdbRow.trendingDay, TmdbRow.nowPlaying, TmdbRow.onTheAir]));
    expect(requests.containsKey(TmdbRow.topRatedTv), isFalse);
    await press(tester, LogicalKeyboardKey.arrowDown, repeats: 6);
    expect(focused, 'row9#0');
    expect(requests[TmdbRow.topRatedTv], 1);
    await unmount(tester);
    slow.complete(const []);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('进入详情停止后续预取，返回首页才继续，完成回调不抢焦点', (tester) async {
    final slow = Completer<List<TmdbTitle>>();
    final requests = <TmdbRow, int>{};
    await pumpHome(
      tester,
      requests: requests,
      fetch: (r) => r == TmdbRow.onTheAir || r == TmdbRow.trendingWeek ? slow.future : titles(r),
    );
    expect(requests.containsKey(TmdbRow.animeToday), isFalse);
    await press(tester, LogicalKeyboardKey.select);
    expect(find.text('暂无可播放资源'), findsOneWidget);
    slow.complete(const []);
    await tester.pumpAndSettle();
    expect(requests.containsKey(TmdbRow.animeToday), isFalse);
    await press(tester, LogicalKeyboardKey.escape);
    expect(requests.containsKey(TmdbRow.animeToday), isTrue);
    expect(focused, 'hero#0');
    await unmount(tester);
  });

  testWidgets('屏外下一行的首屏海报提前准备，不挂载整行或预取全部海报', (tester) async {
    final client = RecordingImages();
    await pumpHome(
      tester,
      client: client,
      fetch: (row) => row == TmdbRow.onTheAir
          ? [for (var i = 0; i < 30; i++) TmdbTitle(id: i, isTv: true, title: '待看-$i', posterPath: '/ahead-$i.jpg')]
          : titles(row),
    );
    expect(find.text('待看-0'), findsNothing);
    final images = client.requested.where((r) => r.path.startsWith('/ahead-')).toSet();
    // 预取接下来两行未挂载行的首屏海报（每行最多 8 张），不预取整行
    expect(images.length, inInclusiveRange(1, 16));
    expect(images.any((r) => r.path == '/ahead-0.jpg'), isTrue);
    expect(images.any((r) => r.path == '/ahead-29.jpg'), isFalse);
    expect(images.every((r) => r.size == 'w342'), isTrue);
    await unmount(tester);
  });

  testWidgets('长按下跨过未挂载行，行销毁后恢复原作品和横向位置', (tester) async {
    await pumpHome(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    final firstRowOffset = verticalController(tester).offset;
    await press(tester, LogicalKeyboardKey.arrowRight, repeats: 11);
    expect(focused, 'row3#12');
    expect(verticalController(tester).offset, closeTo(firstRowOffset, 1));
    await press(tester, LogicalKeyboardKey.arrowDown, repeats: 5);
    expect(focused, 'row9#0');
    expect(find.text('nowPlaying-12'), findsNothing);
    expect(find.byType(PosterCard).evaluate().length, lessThan(40));
    await press(tester, LogicalKeyboardKey.arrowUp, repeats: 5);
    expect(focused, 'row3#12');
    expect(find.text('nowPlaying-12'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused, 'hero#0');
    await unmount(tester);
  });

  testWidgets('加载中的行有焦点锚点，内容到达后留在本行', (tester) async {
    final loading = Completer<List<TmdbTitle>>();
    await pumpHome(tester, fetch: (r) => r == TmdbRow.onTheAir ? loading.future : titles(r));
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'buttons4#0');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    final offset = verticalController(tester).offset;
    loading.complete(titles(TmdbRow.onTheAir));
    await tester.pumpAndSettle();
    expect(focused, 'row4#0');
    expect(verticalController(tester).offset, closeTo(offset, 1));
    await unmount(tester);
  });

  testWidgets('离开加载行后，迟到的数据不能抢回焦点', (tester) async {
    final loading = Completer<List<TmdbTitle>>();
    await pumpHome(tester, fetch: (r) => r == TmdbRow.onTheAir ? loading.future : titles(r));
    await press(tester, LogicalKeyboardKey.arrowDown, repeats: 1);
    expect(focused, 'buttons4#0');
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused, 'row3#1');
    loading.complete(titles(TmdbRow.onTheAir));
    await tester.pumpAndSettle();
    expect(focused, 'row3#1');
    await unmount(tester);
  });

  testWidgets('失败行可确认重试，不清空其他行或跳过当前行', (tester) async {
    var failures = true;
    final requests = <TmdbRow, int>{};
    await pumpHome(
      tester,
      requests: requests,
      fetch: (r) {
        if (r == TmdbRow.onTheAir && failures) throw StateError('offline');
        return titles(r);
      },
    );
    await press(tester, LogicalKeyboardKey.arrowDown, repeats: 1);
    expect(find.text('推荐加载失败'), findsOneWidget);
    expect(focused, 'buttons4#0');
    failures = false;
    await press(tester, LogicalKeyboardKey.select);
    expect(focused, 'row4#0');
    expect(requests[TmdbRow.nowPlaying], 1);
    expect(requests[TmdbRow.onTheAir], 2);
    await unmount(tester);
  });

  testWidgets('插入或删除作品后按作品身份恢复，不把焦点留给同位置的另一部', (tester) async {
    var data = titles(TmdbRow.nowPlaying);
    await pumpHome(tester, fetch: (r) => r == TmdbRow.nowPlaying ? data : titles(r));
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight, repeats: 2);
    expect(focused, 'row3#3');
    final focusedNode = FocusManager.instance.primaryFocus!;
    final container = ProviderScope.containerOf(tester.element(find.byType(VioraApp)));
    data = [const TmdbTitle(id: 9999, isTv: true, title: '新作品'), ...data];
    container.invalidate(tmdbRowProvider(TmdbRow.nowPlaying));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(focusedNode));
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('nowPlaying-4'), findsWidgets);
    data = data.where((t) => t.title != 'nowPlaying-4').toList();
    container.invalidate(tmdbRowProvider(TmdbRow.nowPlaying));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.context, isNotNull);
    expect(focused, startsWith('row3#'));
    await unmount(tester);
  });

  testWidgets('鼠标侧栏停留时滚走旧行，键盘返回内容能恢复被回收的作品', (tester) async {
    await pumpHome(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight, repeats: 11);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1800, 100));
    await mouse.moveTo(tester.getCenter(find.byIcon(Icons.home_rounded)));
    await tester.pumpAndSettle();
    expect(focused, 'nav:/');
    final controller = verticalController(tester);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('nowPlaying-12'), findsNothing);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused, 'row3#12');
    await mouse.removePointer();
    await unmount(tester);
  });

  testWidgets('从虚拟化远端卡片进入详情并返回后保持原作品', (tester) async {
    await pumpHome(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight, repeats: 11);
    await press(tester, LogicalKeyboardKey.select);
    expect(find.text('暂无可播放资源'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused, 'row3#12');
    await unmount(tester);
  });

  testWidgets('快速反向导航取消旧目标，焦点与滚动最终回到 Hero', (tester) async {
    await pumpHome(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(focused, 'hero#0');
    expect(verticalController(tester).offset, 0);
    await unmount(tester);
  });

  testWidgets('系统减少动画时纵横向导航直接定位，仍能恢复原作品', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpHome(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight, repeats: 11);
    expect(focused, 'row3#12');
    await press(tester, LogicalKeyboardKey.arrowDown, repeats: 5);
    expect(focused, 'row9#0');
    await press(tester, LogicalKeyboardKey.arrowUp, repeats: 5);
    expect(focused, 'row3#12');
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused, 'hero#0');
    expect(verticalController(tester).offset, 0);
    await unmount(tester);
  });

  testWidgets('继续观看行移除时转到下一行，不丢焦点或回到页首', (tester) async {
    await pumpHome(
      tester,
      overrides: [
        configProvider.overrideWith(HomeConfig.new),
        resumeProvider.overrideWith((ref) => AsyncData(ref.watch(resumeFixture))),
        mediaFeedStateProvider.overrideWith(
          (ref, kind) => const AsyncData(MediaFeedResult(SnapshotBatch<List<MediaItem>>([]))),
        ),
      ],
    );
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'row1#0');
    final container = ProviderScope.containerOf(tester.element(find.byType(VioraApp)));
    container.read(resumeFixture.notifier).clear();
    await tester.pumpAndSettle();
    expect(focused, 'row3#0');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('续播电影'), findsNothing);
    await unmount(tester);
  });
}
