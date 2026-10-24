import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/platform_profile.dart';
import 'package:viora/data/cache/snapshot_cache.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/data/media/server_registry.dart';
import 'package:viora/data/tmdb/tmdb_client.dart';
import 'package:viora/features/home/home_hero.dart';
import 'package:viora/ui/rows/cards.dart';
import 'package:viora/ui/widgets/backdrop.dart';
import 'package:viora/ui/widgets/cached_image.dart';

import 'home_lazy_test.dart' as fixtures;

ImageInfo frame() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.indigo, BlendMode.src);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(8, 8);
  picture.dispose();
  return ImageInfo(image: image);
}

Future<Completer<ImageInfo>> gateImage(int index) async {
  final provider = netImage('https://image.tmdb.org/t/p/w1280/hero-$index.jpg', cacheWidth: 1280);
  final key = await provider.obtainKey(ImageConfiguration.empty);
  final gate = Completer<ImageInfo>();
  PaintingBinding.instance.imageCache.putIfAbsent(key, () => OneFrameImageStreamCompleter(gate.future));
  return gate;
}

HomeHero hero(WidgetTester tester) => tester.widget<HomeHero>(find.byType(HomeHero));
PageBackdrop backdrop(WidgetTester tester) => tester.widget<PageBackdrop>(find.byType(PageBackdrop));

Future<void> switchNext(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('下一部推荐'));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    PlatformProfile.debugOverride = PlatformProfile.desktop;
  });

  testWidgets('背景就绪前保留旧作品与操作，完成后同时切换标题和背景', (tester) async {
    (await gateImage(0)).complete(frame());
    final next = await gateImage(1);
    await fixtures.pumpHome(tester);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await switchNext(tester);
    expect(hero(tester).index, 0);
    expect(hero(tester).pendingIndex, 1);
    expect(backdrop(tester).imageKey, fixtures.titles(TmdbRow.trendingDay)[0].key);
    next.complete(frame());
    await tester.pumpAndSettle();
    expect(hero(tester).index, 1);
    expect(hero(tester).pendingIndex, isNull);
    expect(backdrop(tester).imageKey, fixtures.titles(TmdbRow.trendingDay)[1].key);
    await fixtures.unmount(tester);
  });

  testWidgets('快速连续选择后旧图片迟到不覆盖最新作品', (tester) async {
    (await gateImage(0)).complete(frame());
    final first = await gateImage(1);
    final second = await gateImage(2);
    await fixtures.pumpHome(tester);
    await switchNext(tester);
    await switchNext(tester);
    expect(hero(tester).pendingIndex, 2);
    second.complete(frame());
    await tester.pumpAndSettle();
    expect(hero(tester).index, 2);
    first.complete(frame());
    await tester.pumpAndSettle();
    expect(hero(tester).index, 2);
    expect(backdrop(tester).imageKey, fixtures.titles(TmdbRow.trendingDay)[2].key);
    await fixtures.unmount(tester);
  });

  testWidgets('图片超时后展示新作品占位，迟到图片不会重新覆盖页面', (tester) async {
    (await gateImage(0)).complete(frame());
    final next = await gateImage(1);
    await fixtures.pumpHome(tester);
    await switchNext(tester);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(hero(tester).index, 1);
    expect(backdrop(tester).image, isNull);
    next.complete(frame());
    await tester.pumpAndSettle();
    expect(backdrop(tester).image, isNull);
    await fixtures.unmount(tester);
  });

  testWidgets('图片准备中进入详情，返回后取消旧目标且保持原作品', (tester) async {
    (await gateImage(0)).complete(frame());
    final next = await gateImage(1);
    await fixtures.pumpHome(tester);
    await switchNext(tester);
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(find.text('暂无可播放资源'), findsOneWidget);
    next.complete(frame());
    await tester.pumpAndSettle();
    await fixtures.press(tester, LogicalKeyboardKey.escape);
    expect(hero(tester).index, 0);
    expect(hero(tester).pendingIndex, isNull);
    await fixtures.unmount(tester);
  });

  testWidgets('推荐列表刷新重排后仍展示同一作品，删除后回落到有效项', (tester) async {
    (await gateImage(0)).complete(frame());
    (await gateImage(1)).complete(frame());
    var data = fixtures.titles(TmdbRow.trendingDay);
    await fixtures.pumpHome(tester, fetch: (row) => row == TmdbRow.trendingDay ? data : fixtures.titles(row));
    await switchNext(tester);
    final key = hero(tester).items[hero(tester).index].key;
    data = [data[2], data[0], data[1], ...data.skip(3)];
    final container = ProviderScope.containerOf(tester.element(find.byType(HomeHero)));
    container.invalidate(tmdbRowProvider(TmdbRow.trendingDay));
    await tester.pumpAndSettle();
    expect(hero(tester).index, 2);
    expect(hero(tester).items[hero(tester).index].key, key);
    expect(backdrop(tester).imageKey, key);
    data = data.where((t) => t.key != key).toList();
    container.invalidate(tmdbRowProvider(TmdbRow.trendingDay));
    await tester.pumpAndSettle();
    expect(hero(tester).pendingIndex, isNull);
    expect(backdrop(tester).imageKey, hero(tester).items[hero(tester).index].key);
    await fixtures.unmount(tester);
  });

  for (final size in [const Size(1280, 720), const Size(1920, 1080)]) {
    testWidgets('TV $size 首屏包含继续观看卡片及操作区', (tester) async {
      await fixtures.pumpHome(
        tester,
        viewport: size,
        overrides: [
          configProvider.overrideWith(fixtures.HomeConfig.new),
          resumeProvider.overrideWith((ref) => AsyncData(ref.watch(fixtures.resumeFixture))),
          mediaFeedStateProvider.overrideWith(
            (ref, kind) => const AsyncData(MediaFeedResult(SnapshotBatch<List<MediaItem>>([]))),
          ),
        ],
      );
      final card = tester.getRect(find.byType(LandscapeCard).first);
      expect(card.bottom, lessThanOrEqualTo(size.height));
      expect(card.top, greaterThan(0));
      expect(find.text('播放'), findsNothing); // 当前 Hero 是 TMDB 推荐，使用详情入口。
      expect(find.text('查看详情'), findsOneWidget);
      await fixtures.unmount(tester);
    });
  }

  testWidgets('暂停状态在 Hero 行被回收并重新挂载后保留', (tester) async {
    (await gateImage(0)).complete(frame());
    await fixtures.pumpHome(tester);
    await tester.tap(find.bySemanticsLabel('暂停自动轮播'));
    await tester.pumpAndSettle();
    await fixtures.press(tester, LogicalKeyboardKey.arrowDown, repeats: 6);
    expect(find.byType(HomeHero), findsNothing);
    await fixtures.press(tester, LogicalKeyboardKey.arrowUp, repeats: 6);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(hero(tester).rotationPaused, isTrue);
    expect(find.bySemanticsLabel('开启自动轮播'), findsOneWidget);
    await fixtures.unmount(tester);
  });

  testWidgets('Windows 普通滚轮纵向、Shift 与横向输入行内滚动，行尾可继续下翻', (tester) async {
    await fixtures.pumpHome(tester, profile: PlatformProfile.desktop);
    await fixtures.press(tester, LogicalKeyboardKey.arrowDown);
    final vertical = fixtures.verticalController(tester);
    final horizontal = tester
        .widget<ListView>(find.byWidgetPredicate((w) => w is ListView && w.scrollDirection == Axis.horizontal).first)
        .controller!;
    Future<void> scroll(Offset delta) async {
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(PosterCard).hitTestable().first),
          scrollDelta: delta,
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pumpAndSettle();
    }

    var v = vertical.offset;
    await scroll(const Offset(0, 80));
    expect(vertical.offset, greaterThan(v));
    expect(horizontal.offset, 0);
    v = vertical.offset;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await scroll(const Offset(0, 100));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(horizontal.offset, 100);
    expect(vertical.offset, v);
    await scroll(const Offset(80, 0));
    expect(horizontal.offset, 180);
    expect(vertical.offset, v);
    horizontal.jumpTo(horizontal.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await scroll(const Offset(0, 80));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(vertical.offset, greaterThan(v));
    expect(horizontal.offset, horizontal.position.maxScrollExtent);
    await fixtures.unmount(tester);
  });
}
