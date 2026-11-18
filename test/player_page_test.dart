import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/app/input/back_handler.dart';
import 'package:viora/app/input/intents.dart';
import 'package:viora/app/platform_profile.dart';
import 'package:viora/app/window_frame.dart';
import 'package:viora/data/aggregate/sources.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/history/pending_reports.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/data/media/server_registry.dart';
import 'package:viora/features/player/player_page.dart';
import 'package:viora/player/engine.dart';
import 'package:viora/ui/widgets/server_image.dart';
import 'package:viora/player/preload.dart';

/// 假的播放内核：打开即开始播放，记录快进 / 快退
class FakeEngine extends PlayerEngine {
  final _state = ValueNotifier(const EngineState());
  final seeks = <Duration>[];
  final _completed = StreamController<void>.broadcast();
  final _errors = StreamController<EngineError>.broadcast();

  @override
  EngineKind get kind => EngineKind.mpv;
  @override
  ValueListenable<EngineState> get state => _state;
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<EngineError> get errors => _errors.stream;

  /// 每次打开的起播位置
  final opened = <Duration>[];

  @override
  Future<void> open(EngineMedia media) async {
    opened.add(media.start);
    _state.value = EngineState(
      position: media.start,
      duration: const Duration(minutes: 20),
      playing: true,
      buffering: false,
    );
  }

  /// 内核报的下载状态
  void report({int? speed, Duration? buffered}) =>
      _state.value = _state.value.copyWith(speed: speed, buffered: buffered);

  @override
  Future<void> play() async => _state.value = _state.value.copyWith(playing: true);
  @override
  Future<void> pause() async => _state.value = _state.value.copyWith(playing: false);
  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    _state.value = _state.value.copyWith(position: position);
  }

  @override
  Future<void> setRate(double rate) async => _state.value = _state.value.copyWith(rate: rate);

  /// 最后设置的音量（0–1）
  double volume = 1;
  Duration subtitleDelay = Duration.zero;
  VideoFit fit = VideoFit.contain;
  @override
  bool get supportsSubtitleDelay => true;
  @override
  Future<void> setSubtitleDelay(Duration delay) async => subtitleDelay = delay;
  @override
  Future<void> setVideoFit(VideoFit fit) async => this.fit = fit;
  @override
  Future<void> setVolume(double volume) async => this.volume = volume;
  @override
  Future<void> selectAudio(EngineTrack track) async {}
  @override
  Future<void> selectSubtitle(EngineTrack? track) async {}
  @override
  Future<void> addExternalSubtitle(Uri url, {String? title, String? language}) async {}
  @override
  // 和安卓上的原生视频画面（PlatformViewLink）一样：画面本身带一个铺满全屏、可以聚焦的节点
  Widget buildView() => Focus(
    debugLabel: 'video-view',
    child: const ColoredBox(color: Colors.black),
  );
  @override
  Future<void> dispose() async {
    await _completed.close();
    await _errors.close();
  }
}

const server = ServerConfig(
  id: 's',
  name: 'fixture',
  type: ServerType.emby,
  username: 'u',
  userId: 'u',
  token: 't',
  lines: [],
);

MediaItem episode(int season, int number, {Duration position = Duration.zero}) => MediaItem(
  serverId: 's',
  position: position,
  id: 's${season}e$number',
  name: '第 $number 集',
  kind: MediaKind.episode,
  seriesId: 'show',
  seriesName: '测试剧',
  seasonId: 'season$season',
  seasonNumber: season,
  episodeNumber: number,
);

/// 假服务器：第 1 季 3 集、第 2 季 1 集
class PlayerClient extends EmbyClient {
  PlayerClient()
    : super(
        config: const AppConfig(servers: [server]),
        server: server,
        appVersion: 'test',
      );

  /// 第 1 季的集数（测试长剧时调大）
  static int seasonOne = 3;

  final all = [for (var i = 1; i <= seasonOne; i++) episode(1, i), episode(2, 1)];

  /// 服务器上这一集最新的进度（别的设备看过）
  Duration serverPosition = Duration.zero;

  /// Emby 章节上的片尾标记（片尾开始的位置）
  Duration? creditsStart;
  @override
  Future<List<ServerChapter>> chapters(String itemId) async => [
    if (creditsStart != null) ServerChapter(name: '片尾', start: creditsStart!, marker: 'CreditsStart'),
  ];
  @override
  Future<MediaItem> item(String id) async {
    final e = all.firstWhere((e) => e.id == id);
    return serverPosition == Duration.zero ? e : episode(e.seasonNumber!, e.episodeNumber!, position: serverPosition);
  }

  @override
  Future<PlaybackInfoResult> playbackInfo(String itemId, {bool isPlayback = false}) async => (
    sources: [
      MediaSourceInfo(
        serverId: 's',
        itemId: itemId,
        id: 'src',
        container: 'mkv',
        streams: const [MediaStreamInfo(index: 0, type: 'Video', width: 3840, height: 2160)],
      ),
    ],
    playSessionId: 'p',
  );
  @override
  PlaybackRequest stream(MediaSourceInfo source, {String? playSessionId}) => PlaybackRequest(
    url: Uri.parse('https://media.invalid/${source.itemId}.mkv'),
    headers: const {'User-Agent': 'test'},
    userAgent: 'test',
  );
  @override
  Future<List<MediaItem>> episodes(String seriesId, {String? seasonId}) async => [
    for (final e in all)
      if (seasonId == null || e.seasonId == seasonId) e,
  ];
  @override
  Future<void> reportStart(MediaSourceInfo s, Duration position, String? playSessionId) async {}

  /// 进度上报（事件, 位置）
  final progress = <(String, Duration)>[];
  @override
  Future<void> reportProgress(
    MediaSourceInfo s,
    Duration position,
    String? playSessionId, {
    bool paused = false,
    String event = 'TimeUpdate',
  }) async => progress.add((event, position));

  /// 停止上报的位置
  final stopped = <Duration>[];

  /// 停止上报失败（服务器连不上 / 应用被关掉）
  bool stopFails = false;

  @override
  Future<bool> reportStopped(MediaSourceInfo s, Duration position, String? playSessionId) async {
    stopped.add(position);
    return !stopFails;
  }
}

class OneServer extends ConfigStore {
  @override
  AppConfig build() => const AppConfig(playback: PlaybackConfig(preload: false), servers: [server]);
}

String? get focused => FocusManager.instance.primaryFocus?.debugLabel;

/// 和应用一样：返回键先交给页面（BackHandler），没人处理就出栈
void appBack(GoRouter router) {
  if (!backDispatcher.dispatch()) router.pop();
}

class Harness {
  Harness(this.router, this.engines, this.client);
  final GoRouter router;
  final List<FakeEngine> engines;
  final PlayerClient client;
  FakeEngine get engine => engines.last;
}

Future<Harness> pumpPlayer(
  WidgetTester tester, {
  String itemId = 's1e2',
  List<Override> overrides = const [],
  int startMs = 0,
  bool resume = false,
  Duration serverPosition = Duration.zero,
  Duration? creditsStart,
}) async {
  PlatformProfile.debugOverride = PlatformProfile.tv;
  SharedPreferences.setMockInitialValues({});
  ConfigStore.vault = MemoryVault();
  PlaybackPreloader.reset();
  PlayerPage.debugClearEpisodeCache();
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final engines = <FakeEngine>[];
  PlayerPage.debugEngineFactory = (_) => FakeEngine()..let(engines.add);
  addTearDown(() => PlayerPage.debugEngineFactory = null);
  final client = PlayerClient()
    ..serverPosition = serverPosition
    ..creditsStart = creditsStart;
  late final GoRouter router;
  router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('详情页')),
      ),
      GoRoute(
        path: '/play',
        builder: (_, _) => PlayerPage(serverId: 's', itemId: itemId, startMs: startMs, resume: resume),
      ),
      // 连播下一集（片尾自动下一集、上一集 / 下一集）
      GoRoute(
        path: '/play/:sid/:id',
        builder: (_, state) => PlayerPage(serverId: 's', itemId: state.pathParameters['id']!),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        configProvider.overrideWith(OneServer.new),
        serverClientProvider.overrideWith((ref, id) => client),
        ...overrides,
      ],
      child: MaterialApp.router(
        routerConfig: router,
        shortcuts: {...WidgetsApp.defaultShortcuts, ...appShortcuts},
        actions: {
          ...WidgetsApp.defaultActions,
          BackIntent: CallbackAction<BackIntent>(onInvoke: (_) => appBack(router)),
        },
      ),
    ),
  );
  unawaited(router.push('/play'));
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await tester.pumpAndSettle();
  return Harness(router, engines, client);
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

Future<void> unmountPlayer(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  PlatformProfile.debugOverride = PlatformProfile.desktop;
}

extension<T> on T {
  void let(void Function(T) f) => f(this);
}

void main() {
  testWidgets('电视：画面上 ←→ 快进快退；↓ 到底部按钮行，按钮按顺序左右移动', (tester) async {
    final h = await pumpPlayer(tester);
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(focused, 'player');
    await press(tester, LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(seconds: 1));
    expect(h.engine.seeks, [const Duration(seconds: 10)]);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'osd-play');
    await unmountPlayer(tester);
  });

  testWidgets('电视：选集面板打开后焦点在正在看的集，返回先关面板回到画面，默认画面再按才退出', (tester) async {
    final h = await pumpPlayer(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.text('选集 · 共 3 集：'), findsOneWidget);
    expect(focused, 'panel-entry');

    // 系统返回（安卓遥控器）：先回到默认画面
    appBack(h.router);
    await tester.pumpAndSettle();
    expect(find.text('选集 · 共 3 集：'), findsNothing);
    expect(focused, 'player');
    expect(find.byType(PlayerPage), findsOneWidget);

    // 键盘返回（Esc）同样先回到画面；默认画面上再按才退出
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused, 'player');
    expect(find.byType(PlayerPage), findsOneWidget);
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byType(PlayerPage), findsNothing);
    expect(find.text('详情页'), findsOneWidget);
    await unmountPlayer(tester);
  });

  testWidgets('电视：按钮行按 ↑ 到顶部按钮；倍速菜单可以选择，关闭后焦点回到倍速按钮', (tester) async {
    final h = await pumpPlayer(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowUp);
    final top = FocusManager.instance.primaryFocus!.rect;
    expect(top.top, lessThan(200), reason: '焦点应在顶部的弹幕 / 音轨 / 字幕 / 更多');
    await press(tester, LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 4; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.text('倍速'), findsWidgets);
    // 菜单第一项是 0.5x
    await press(tester, LogicalKeyboardKey.enter);
    expect(h.engine.state.value.rate, 0.5);
    expect(find.text('0.5x'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus!.rect.top, greaterThan(900));
    await unmountPlayer(tester);
  });

  testWidgets('电视：画面上直接按 ↑ 选中顶部按钮；菜单贴着按下的按钮弹出', (tester) async {
    await pumpPlayer(tester);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(FocusManager.instance.primaryFocus!.debugLabel, 'osd-top');
    // 顶部的「更多」：菜单在按钮下面
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    final button = FocusManager.instance.primaryFocus!.rect;
    await press(tester, LogicalKeyboardKey.enter);
    final menu = FocusManager.instance.primaryFocus!.rect;
    expect(menu.top, greaterThan(button.bottom));
    expect(menu.top - button.bottom, lessThan(150));
    expect(menu.left <= button.right && menu.right >= button.left, isTrue, reason: '菜单和按钮上下对齐');
    await press(tester, LogicalKeyboardKey.escape);
    // 底部的倍速按钮：菜单在按钮上面
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 4; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    final rate = FocusManager.instance.primaryFocus!.rect;
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.text('倍速'), findsWidgets);
    final item = FocusManager.instance.primaryFocus!.rect;
    expect(item.bottom, lessThan(rate.top));
    expect(item.left <= rate.right && item.right >= rate.left, isTrue, reason: '菜单和按钮上下对齐');
    await unmountPlayer(tester);
  });

  testWidgets('电视：选集面板可以切换季，默认是正在看的那一季', (tester) async {
    await pumpPlayer(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.text('第 1 季'), findsOneWidget);
    expect(find.text('第 2 季'), findsOneWidget);
    expect(find.text('选集 · 共 3 集：'), findsOneWidget);
    // 集卡片按 ↑ 到季按钮，选第 2 季
    await press(tester, LogicalKeyboardKey.arrowUp);
    var guard = 0;
    while (FocusManager.instance.primaryFocus!.rect.left < tester.getRect(find.text('第 2 季')).left - 40 &&
        guard++ < 4) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.text('选集 · 共 1 集：'), findsOneWidget);
    // ↓ 回到这一季的集
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(FocusManager.instance.primaryFocus!.rect.top, greaterThan(tester.getRect(find.text('第 2 季')).bottom));
    await unmountPlayer(tester);
  });

  testWidgets('电视：焦点从按钮上掉下来（按钮消失等）会回到画面，暂停照常能用', (tester) async {
    final h = await pumpPlayer(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'osd-play');
    // 模拟按钮消失：焦点落到页面的空容器上
    FocusManager.instance.primaryFocus!.unfocus();
    await tester.pumpAndSettle();
    expect(focused, 'player');
    expect(h.engine.state.value.playing, isTrue);
    await press(tester, LogicalKeyboardKey.enter);
    expect(h.engine.state.value.playing, isFalse);
    await unmountPlayer(tester);
  });

  testWidgets('控制层隐藏时进度变化不重建，缓冲变化、重新显示时拿到最新状态', (tester) async {
    final state = ValueNotifier(const EngineState());
    var builds = 0;
    Widget host(bool live) => Directionality(
      textDirection: TextDirection.ltr,
      child: EngineStateBuilder(
        state: state,
        live: live,
        builder: (context, s) {
          builds++;
          return Text('${s.position.inSeconds}');
        },
      ),
    );
    await tester.pumpWidget(host(false));
    expect(builds, 1);
    state.value = state.value.copyWith(position: const Duration(seconds: 5));
    await tester.pump();
    expect(builds, 1);
    state.value = state.value.copyWith(buffering: false);
    await tester.pump();
    expect(builds, 2);
    expect(find.text('5'), findsOneWidget);
    state.value = state.value.copyWith(position: const Duration(seconds: 9));
    await tester.pump();
    expect(builds, 2);
    // 控制层显示：上层重建，拿到最新进度；之后跟着进度走
    await tester.pumpWidget(host(true));
    expect(find.text('9'), findsOneWidget);
    state.value = state.value.copyWith(position: const Duration(seconds: 10));
    await tester.pump();
    expect(find.text('10'), findsOneWidget);
  });

  testWidgets('电视：底部每个按钮按 ↑ 都到顶部按钮，不会落到视频画面自带的焦点节点上', (tester) async {
    await pumpPlayer(tester);
    for (var rights = 0; rights < 5; rights++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
      for (var i = 0; i < rights; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(FocusManager.instance.primaryFocus!.rect.top, greaterThan(900));
      await press(tester, LogicalKeyboardKey.arrowUp);
      final top = FocusManager.instance.primaryFocus!;
      expect(top.debugLabel, isNot('video-view'), reason: '第 ${rights + 1} 个按钮');
      expect(top.rect.bottom, lessThan(200), reason: '第 ${rights + 1} 个按钮');
      // 回到画面，下一轮重新从播放按钮开始
      await press(tester, LogicalKeyboardKey.escape);
    }
    await unmountPlayer(tester);
  });

  testWidgets('右上角：时间在最右边，下载状态变长时时间和按钮的位置不变', (tester) async {
    final h = await pumpPlayer(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    Finder clock() => find.byKey(const ValueKey('osd-clock'));
    h.engine.report(speed: 6400000);
    await tester.pump();
    final clockAt = tester.getTopLeft(clock());
    final more = tester.getTopLeft(find.byIcon(Icons.more_horiz_rounded));
    expect(clockAt.dx, greaterThan(more.dx), reason: '时间在按钮右边');
    expect(find.text('6.1 MB/s'), findsOneWidget);
    h.engine.report(speed: 0, buffered: const Duration(minutes: 12, seconds: 34));
    await tester.pump();
    expect(find.textContaining('已缓冲'), findsOneWidget);
    expect(tester.getTopLeft(clock()), clockAt);
    expect(tester.getTopLeft(find.byIcon(Icons.more_horiz_rounded)), more);
    await unmountPlayer(tester);
  });

  testWidgets('电视：80 集的季只构建屏幕附近的几张卡片，打开时焦点在正在看的第 40 集上', (tester) async {
    PlayerClient.seasonOne = 80;
    addTearDown(() => PlayerClient.seasonOne = 3);
    await pumpPlayer(tester, itemId: 's1e40');
    await press(tester, LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.text('选集 · 共 80 集：'), findsOneWidget);
    expect(focused, 'panel-entry');
    // 正在看的那一集在屏幕中间
    final rect = FocusManager.instance.primaryFocus!.rect;
    expect(rect.center.dx, closeTo(960, 200));
    expect(find.text('正在播放'), findsOneWidget);
    // 只有屏幕上和两侧缓存的卡片（1920 宽，每张 340）
    expect(find.byType(ServerImage).evaluate().length, lessThan(14));
    // ←→ 照常逐集移动
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('第 41 集'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus!.rect.center.dx, closeTo(960, 200));
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused, 'panel-entry');
    await unmountPlayer(tester);
  });

  testWidgets('电视：其他服务器还在查找时，「播放资源」面板先显示当前这台的版本，焦点能进去', (tester) async {
    final never = Completer<List<SourceOption>>();
    await pumpPlayer(tester, overrides: [sourceOptionsProvider.overrideWith((ref, key) => never.future)]);
    await press(tester, LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 2; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('正在查找各服务器上的资源…'), findsOneWidget);
    expect(find.text('fixture'), findsWidgets, reason: '当前服务器的版本卡片已经显示');
    expect(focused, 'panel-entry');
    await unmountPlayer(tester);
  });

  testWidgets('电视：应用退到后台时暂停，回到前台保持暂停；Windows 最小化后继续播放', (tester) async {
    final h = await pumpPlayer(tester);
    expect(h.engine.state.value.playing, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(h.engine.state.value.playing, isTrue, reason: '只是失去焦点（弹出系统对话框等）不暂停');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(h.engine.state.value.playing, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(h.engine.state.value.playing, isFalse);

    // Windows：同样的生命周期变化不暂停
    await press(tester, LogicalKeyboardKey.enter);
    expect(h.engine.state.value.playing, isTrue);
    PlatformProfile.debugOverride = PlatformProfile.desktop;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(h.engine.state.value.playing, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await unmountPlayer(tester);
  });

  testWidgets('Windows：鼠标移出控制栏后按钮不保持高亮；键盘移动的焦点不动', (tester) async {
    await pumpPlayer(tester);
    PlatformProfile.debugOverride = PlatformProfile.desktop;
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    // 鼠标移到「倍速」上：拿到焦点（白色高亮）
    final rate = tester.getCenter(find.text('倍速'));
    await gesture.addPointer(location: const Offset(960, 400));
    await gesture.moveTo(rate);
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(rate + const Offset(2, 0));
    await tester.pump(const Duration(milliseconds: 50));
    expect(FocusManager.instance.primaryFocus!.rect.contains(rate), isTrue);
    // 移出控制栏：焦点回到画面
    await gesture.moveTo(const Offset(960, 400));
    await tester.pump(const Duration(milliseconds: 50));
    expect(focused, 'player');
    await unmountPlayer(tester);
  });

  testWidgets('Windows：↑↓ 调音量、M 静音、滚轮和音量滑块；音量存进设置；电视上 ↑↓ 照常移动焦点', (tester) async {
    final h = await pumpPlayer(tester);
    PlatformProfile.debugOverride = PlatformProfile.desktop;
    // 回到画面（默认焦点在画面上）
    expect(focused, 'player');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(h.engine.volume, closeTo(0.95, 0.001));
    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(h.engine.volume, closeTo(0.80, 0.001));
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(h.engine.volume, closeTo(0.85, 0.001));
    // 不会超过 100%
    for (var i = 0; i < 5; i++) {
      await press(tester, LogicalKeyboardKey.arrowUp);
    }
    expect(h.engine.volume, 1);
    // M 静音 / 取消静音，音量记得原来的
    await press(tester, LogicalKeyboardKey.keyM);
    expect(h.engine.volume, 0);
    await press(tester, LogicalKeyboardKey.keyM);
    expect(h.engine.volume, 1);

    // 滚轮：向下滚变小
    final center = tester.getCenter(find.byType(PlayerPage));
    tester.binding.handlePointerEvent(PointerScrollEvent(position: center, scrollDelta: const Offset(0, 50)));
    await tester.pump();
    expect(h.engine.volume, closeTo(0.95, 0.001));

    // 底部音量滑块：点在中间 = 50%
    await tester.pump();
    final slider = find.byKey(const ValueKey('volume-slider'));
    expect(slider, findsOneWidget);
    await tester.tapAt(tester.getCenter(slider));
    await tester.pump();
    expect(h.engine.volume, closeTo(0.5, 0.01));

    // 停一下后存进设置，下次播放沿用
    await tester.pump(const Duration(seconds: 1));
    final container = ProviderScope.containerOf(tester.element(find.byType(PlayerPage)));
    expect(container.read(configProvider).playback.volume, closeTo(0.5, 0.01));
    await unmountPlayer(tester);
  });

  testWidgets('数字键跳到 N0%；Windows：Shift+→ 60 秒、[ ] \\ 调倍速、Ctrl+→ 字幕推后', (tester) async {
    final h = await pumpPlayer(tester);
    // 电视数字键 5 → 50%（总长 20 分钟）
    await press(tester, LogicalKeyboardKey.digit5);
    await tester.pump(const Duration(seconds: 1));
    expect(h.engine.seeks.last, const Duration(minutes: 10));

    PlatformProfile.debugOverride = PlatformProfile.desktop;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(const Duration(seconds: 1));
    expect(h.engine.seeks.last, const Duration(minutes: 11));

    await press(tester, LogicalKeyboardKey.bracketRight);
    expect(h.engine.state.value.rate, 1.25);
    await press(tester, LogicalKeyboardKey.bracketLeft);
    await press(tester, LogicalKeyboardKey.bracketLeft);
    expect(h.engine.state.value.rate, 0.75);
    await press(tester, LogicalKeyboardKey.backslash);
    expect(h.engine.state.value.rate, 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(h.engine.subtitleDelay, const Duration(milliseconds: 200));
    // Ctrl+→ 不快进
    await tester.pump(const Duration(seconds: 1));
    expect(h.engine.seeks.last, const Duration(minutes: 11));
    await unmountPlayer(tester);
  });

  testWidgets('电视：按住 → 越按越快（按时间算，不按连发次数）', (tester) async {
    final h = await pumpPlayer(tester);
    PlayerPage.debugNow = () => tester.binding.clock.now();
    addTearDown(() => PlayerPage.debugNow = DateTime.now);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    // 模拟按住 5 秒，每 100 毫秒一次连发
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(seconds: 1));
    // 头 1.5 秒每秒约 1 分钟、到 4 秒每秒约 4 分钟、之后每秒约 16 分钟：5 秒到片尾（20 分钟）附近
    expect(h.engine.seeks.last, greaterThan(const Duration(minutes: 15)));
    await unmountPlayer(tester);
  });

  testWidgets('关闭播放器时内核已经停了（位置报 0）：停止上报仍用最后的播放位置，不把服务器进度清掉', (tester) async {
    final h = await pumpPlayer(tester);
    await h.engine.seek(const Duration(minutes: 7));
    await tester.pump();
    // 内核关闭 / 停下时位置变成 0
    h.engine.report(speed: 0);
    await h.engine.seek(Duration.zero);
    await tester.pump();
    await unmountPlayer(tester);
    expect(h.client.stopped, [const Duration(minutes: 7)]);
  });

  testWidgets('内核报 0 时暂停：暂停上报也用最后的播放位置；真的拖回开头时报 0', (tester) async {
    final h = await pumpPlayer(tester);
    await h.engine.seek(const Duration(minutes: 7));
    await tester.pump();
    // 内核位置变成 0（如刚切换、停下时）后暂停
    await h.engine.seek(Duration.zero);
    await tester.pump();
    await press(tester, LogicalKeyboardKey.enter);
    expect(h.client.progress.last, ('Pause', const Duration(minutes: 7)));

    // 用户真的拖回开头（数字键 0 在电视上不响应，用 ← 快退到 0）
    await press(tester, LogicalKeyboardKey.enter); // 继续播放
    for (var i = 0; i < 50; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    }
    await tester.pump(const Duration(seconds: 1));
    await press(tester, LogicalKeyboardKey.enter); // 暂停
    expect(h.client.progress.last, ('Pause', Duration.zero));
    await unmountPlayer(tester);
  });

  testWidgets('继续播放：别的设备看得更靠后时以服务器的最新进度为准；明确指定位置时不变', (tester) async {
    // 卡片上（缓存）是 5 分钟，服务器上别的设备已经看到 12 分钟
    final h = await pumpPlayer(
      tester,
      startMs: 5 * 60 * 1000,
      resume: true,
      serverPosition: const Duration(minutes: 12),
    );
    expect(h.engine.opened.single, const Duration(minutes: 12));
    await unmountPlayer(tester);

    // 切换资源时接着当前位置（不是继续播放）：用给的位置
    final h2 = await pumpPlayer(tester, startMs: 5 * 60 * 1000, serverPosition: const Duration(minutes: 12));
    expect(h2.engine.opened.single, const Duration(minutes: 5));
    await unmountPlayer(tester);
  });

  testWidgets('退出播放后继续观看马上按本机的进度显示（不等服务器刷新）', (tester) async {
    final h = await pumpPlayer(tester);
    await h.engine.seek(const Duration(minutes: 7));
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.byType(PlayerPage)));
    // 退出播放回到上一页（应用还在）
    h.router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPage), findsNothing);
    final local = container.read(localPlaysProvider)['s/s1e2']?.$1;
    expect(local?.position, const Duration(minutes: 7));
    expect(local?.played, isFalse);
    await unmountPlayer(tester);
  });

  testWidgets('停止上报没报上去：存在本机等下次启动补发；报上去了就删掉', (tester) async {
    final h = await pumpPlayer(tester);
    await h.engine.seek(const Duration(minutes: 9));
    await tester.pump();
    h.client.stopFails = true;
    h.router.pop();
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    final left = await tester.runAsync(PendingPlayReports.list);
    expect([for (final r in left!) (r.itemId, r.position)], [('s1e2', const Duration(minutes: 9))]);
    await unmountPlayer(tester);
  });

  testWidgets('Windows 沉浸：控制层隐藏时窗口按钮也隐藏，控制层出来时一起出来，退出播放恢复', (tester) async {
    await pumpPlayer(tester);
    PlatformProfile.debugOverride = PlatformProfile.desktop;
    await tester.pump(const Duration(seconds: 6)); // 播放中 5 秒后控制层隐藏
    await tester.pump();
    expect(windowImmersive.value, isTrue);
    await press(tester, LogicalKeyboardKey.arrowRight); // 有操作：控制层出来
    await tester.pump();
    expect(windowImmersive.value, isFalse);
    await unmountPlayer(tester);
    await tester.pump();
    expect(windowImmersive.value, isFalse);
  });

  testWidgets('Windows 沉浸：控制层隐藏时直接退出播放，标题栏的窗口按钮也恢复', (tester) async {
    await pumpPlayer(tester);
    PlatformProfile.debugOverride = PlatformProfile.desktop;
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(windowImmersive.value, isTrue);
    await unmountPlayer(tester);
    await tester.pump();
    expect(windowImmersive.value, isFalse);
  });

  testWidgets('片尾自动下一集（默认）：先显示 3 秒「下一集」按钮，再倒计时 3 秒，然后播放下一集', (tester) async {
    final h = await pumpPlayer(tester, creditsStart: const Duration(minutes: 18));
    // 片头片尾在起播后后台解析（第三方数据库在测试里很快失败）
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
    }
    await h.engine.seek(const Duration(minutes: 18, seconds: 2));
    await tester.pump();
    await tester.pump();
    expect(find.text('下一集'), findsWidgets, reason: '先显示「下一集」按钮');
    expect(find.textContaining('秒后播放下一集'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('3 秒后播放下一集'), findsOneWidget, reason: '3 秒后变成 3 秒倒计时');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(h.router.state.uri.path, '/play/s/s1e3', reason: '倒计时结束播放下一集');
    await unmountPlayer(tester);
  });
}
