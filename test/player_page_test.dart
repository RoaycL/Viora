import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/app/input/back_handler.dart';
import 'package:viora/app/input/intents.dart';
import 'package:viora/app/platform_profile.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/data/media/server_registry.dart';
import 'package:viora/features/player/player_page.dart';
import 'package:viora/player/engine.dart';
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

  @override
  Future<void> open(EngineMedia media) async => _state.value = EngineState(
    position: media.start,
    duration: const Duration(minutes: 20),
    playing: true,
    buffering: false,
  );
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
  @override
  Future<void> selectAudio(EngineTrack track) async {}
  @override
  Future<void> selectSubtitle(EngineTrack? track) async {}
  @override
  Future<void> addExternalSubtitle(Uri url, {String? title, String? language}) async {}
  @override
  Widget buildView() => const ColoredBox(color: Colors.black);
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

MediaItem episode(int season, int number) => MediaItem(
  serverId: 's',
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

  final all = [episode(1, 1), episode(1, 2), episode(1, 3), episode(2, 1)];

  @override
  Future<MediaItem> item(String id) async => all.firstWhere((e) => e.id == id);
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
  @override
  Future<void> reportProgress(
    MediaSourceInfo s,
    Duration position,
    String? playSessionId, {
    bool paused = false,
    String event = 'TimeUpdate',
  }) async {}
  @override
  Future<void> reportStopped(MediaSourceInfo s, Duration position, String? playSessionId) async {}
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
  Harness(this.router, this.engines);
  final GoRouter router;
  final List<FakeEngine> engines;
  FakeEngine get engine => engines.last;
}

Future<Harness> pumpPlayer(WidgetTester tester, {String itemId = 's1e2'}) async {
  PlatformProfile.debugOverride = PlatformProfile.tv;
  SharedPreferences.setMockInitialValues({});
  ConfigStore.vault = MemoryVault();
  PlaybackPreloader.reset();
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final engines = <FakeEngine>[];
  PlayerPage.debugEngineFactory = (_) => FakeEngine()..let(engines.add);
  addTearDown(() => PlayerPage.debugEngineFactory = null);
  final client = PlayerClient();
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
        builder: (_, _) => PlayerPage(serverId: 's', itemId: itemId),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [configProvider.overrideWith(OneServer.new), serverClientProvider.overrideWith((ref, id) => client)],
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
  return Harness(router, engines);
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
}
