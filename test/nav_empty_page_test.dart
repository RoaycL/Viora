import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/app.dart';
import 'package:viora/app/platform_profile.dart';
import 'package:viora/data/cache/snapshot_cache.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/data/media/server_registry.dart';
import 'package:viora/ui/widgets/skeleton.dart';

import 'focus_navigation_test.dart' show focused, press, pumpApp, tmdbFixtures, unmount;

/// 收藏数据由测试控制：开始时加载中
class FavoritesFeed extends Notifier<AsyncValue<MediaFeedResult>> {
  @override
  AsyncValue<MediaFeedResult> build() => const AsyncValue.loading();
  void arrive(List<MediaItem> items) => state = AsyncValue.data(
    MediaFeedResult(SnapshotBatch([SourceSnapshot(id: 's', status: SnapshotStatus.fresh, value: items)])),
  );
}

/// 有一台服务器（没有地址，不发请求），收藏的作品才算可见
class OneServer extends ConfigStore {
  @override
  AppConfig build() => const AppConfig(
    playback: PlaybackConfig(preload: false),
    servers: [ServerConfig(id: 's', name: 'fixture', username: 'fixture', type: ServerType.emby, lines: [])],
  );
}

final favoritesFeed = NotifierProvider<FavoritesFeed, AsyncValue<MediaFeedResult>>(FavoritesFeed.new);

/// 切到还没有可聚焦内容的页面（加载中 / 空列表）时，导航不能被卡住
void main() {
  tearDown(() => PlatformProfile.debugOverride = PlatformProfile.desktop);

  testWidgets('Windows：打开没有内容的收藏页后，焦点留在导航上，可以继续切换', (tester) async {
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused, 'nav:/');
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'nav:/favorites');
    await press(tester, LogicalKeyboardKey.select);
    expect(find.text('收藏'), findsWidgets);
    expect(focused, 'nav:/favorites');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'nav:/history');
    await press(tester, LogicalKeyboardKey.select);
    expect(focused, 'nav:/history');
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.select);
    expect(focused, 'hero#0');
    await unmount(tester);
  });

  testWidgets('焦点已经落在没有内容的页面上时，方向键仍能回到导航', (tester) async {
    PlatformProfile.debugOverride = PlatformProfile.tv;
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused, 'nav:/favorites');
    await press(tester, LogicalKeyboardKey.select);
    // 页面没有可聚焦的内容时按 ↓：焦点进不去，留在标签上
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'nav:/favorites');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused, 'nav:/history');
    await unmount(tester);
  });

  testWidgets('收藏加载中显示占位，焦点留在标签栏；数据到了替换占位，按 ↓ 进入', (tester) async {
    PlatformProfile.debugOverride = PlatformProfile.tv;
    autoCheckUpdatesOnLaunch = false;
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...tmdbFixtures,
          configProvider.overrideWith(OneServer.new),
          mediaFeedStateProvider.overrideWith(
            (ref, kind) => kind == MediaFeedKind.favorites
                ? ref.watch(favoritesFeed)
                : const AsyncValue.data(MediaFeedResult(SnapshotBatch([]))),
          ),
        ],
        child: const VioraApp(),
      ),
    );
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.select);
    expect(find.byType(SkeletonCard), findsWidgets);
    expect(find.text('加载中…'), findsOneWidget);
    expect(focused, 'nav:/favorites');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'nav:/favorites');

    final container = ProviderScope.containerOf(tester.element(find.byType(VioraApp)));
    container.read(favoritesFeed.notifier).arrive([
      const MediaItem(serverId: 's', id: 'm1', name: '收藏的电影', kind: MediaKind.movie),
    ]);
    await tester.pumpAndSettle();
    expect(find.byType(SkeletonCard), findsNothing);
    expect(find.text('1 部作品'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'favorite');
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });
}
