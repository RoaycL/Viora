import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/danmaku/danmaku_models.dart';
import 'package:viora/features/danmaku/danmaku_layer.dart';
import 'package:viora/player/engine.dart';

void main() {
  Future<(ValueNotifier<EngineState>, DanmakuLayerState)> pump(
    WidgetTester tester,
    List<DanmakuComment> comments, {
    DanmakuConfig config = const DanmakuConfig(),
  }) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = ValueNotifier(const EngineState(playing: true, buffering: false, duration: Duration(minutes: 40)));
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: DanmakuLayer(comments: comments, state: state, config: config),
      ),
    );
    return (state, tester.state<DanmakuLayerState>(find.byType(DanmakuLayer)));
  }

  testWidgets('同时出现的大量弹幕分到不同行，互不重叠', (tester) async {
    final comments = [for (var i = 0; i < 60; i++) DanmakuComment(time: 0.1 + i * 0.01, text: '弹幕测试内容 $i')];
    final (_, layer) = await pump(tester, comments);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final rects = layer.debugRects;
    expect(rects, isNotEmpty);
    // 半屏：最多 floor(540 / (34*1.32)) = 12 行
    expect(rects.length, lessThanOrEqualTo(12));
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        expect(rects[i].$2.overlaps(rects[j].$2), isFalse, reason: '${rects[i].$1} / ${rects[j].$1}');
      }
      expect(rects[i].$2.bottom, lessThanOrEqualTo(1080 * 0.5 + 16 + 1));
    }
  });

  testWidgets('暂停时弹幕停住，播放后继续向左移动', (tester) async {
    final (state, layer) = await pump(tester, const [DanmakuComment(time: 0.05, text: '会动的弹幕')]);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final x1 = layer.debugRects.single.$2.left;
    state.value = state.value.copyWith(playing: false, position: const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 50));
    final paused = layer.debugRects.single.$2.left;
    await tester.pump(const Duration(milliseconds: 500));
    expect(layer.debugRects.single.$2.left, paused);
    state.value = state.value.copyWith(playing: true);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 500));
    expect(layer.debugRects.single.$2.left, lessThan(paused));
    expect(paused, lessThan(x1 + 1));
  });

  testWidgets('拖动进度后从新位置重新出弹幕，旧的清掉', (tester) async {
    final (state, layer) = await pump(tester, const [
      DanmakuComment(time: 0.05, text: '开头'),
      DanmakuComment(time: 600.2, text: '十分钟'),
    ]);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(layer.debugRects.map((r) => r.$1), ['开头']);
    state.value = state.value.copyWith(position: const Duration(seconds: 600));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(layer.debugRects.map((r) => r.$1), ['十分钟']);
  });

  testWidgets('顶部 / 底部弹幕居中，关闭后不显示', (tester) async {
    const comments = [
      DanmakuComment(time: 0.05, text: '顶部', mode: DanmakuMode.top),
      DanmakuComment(time: 0.06, text: '底部', mode: DanmakuMode.bottom),
    ];
    final (_, layer) = await pump(tester, comments);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final rects = {for (final r in layer.debugRects) r.$1: r.$2};
    expect(rects['顶部']!.center.dx, closeTo(960, 1));
    expect(rects['底部']!.top, greaterThan(800));

    final (_, hidden) = await pump(tester, comments, config: const DanmakuConfig(showFixed: false));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(hidden.debugRects, isEmpty);
  });

  testWidgets('播放中调整字号 / 显示区域 / 速度：屏幕上的弹幕就地更新，不清屏', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = ValueNotifier(const EngineState(playing: true, buffering: false, duration: Duration(minutes: 40)));
    final comments = [for (var i = 0; i < 40; i++) DanmakuComment(time: 0.1 + i * 0.01, text: '弹幕内容 $i')];
    Widget build(DanmakuConfig c) => Directionality(
      textDirection: TextDirection.ltr,
      child: DanmakuLayer(comments: comments, state: state, config: c),
    );
    await tester.pumpWidget(build(const DanmakuConfig(area: 1.0)));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final layer = tester.state<DanmakuLayerState>(find.byType(DanmakuLayer));
    final before = layer.debugRects;
    expect(before.length, greaterThan(12), reason: '全屏能放下的行数比半屏多');

    // 字号变大：同样的弹幕还在，宽度变大
    await tester.pumpWidget(build(const DanmakuConfig(area: 1.0, fontSize: 48)));
    final bigger = {for (final r in layer.debugRects) r.$1: r.$2.width};
    // 字号变大后能放下的行变少（1080 / (48×1.32) = 17 行），多出来的行去掉，其余就地变大
    expect(bigger.length, 17);
    for (final r in before) {
      if (bigger.containsKey(r.$1)) expect(bigger[r.$1]!, greaterThan(r.$2.width));
    }

    // 改速度：位置不跳（走过的比例保持）
    final x0 = {for (final r in layer.debugRects) r.$1: r.$2.left};
    await tester.pumpWidget(build(const DanmakuConfig(area: 1.0, fontSize: 48, speed: 6)));
    for (final r in layer.debugRects) {
      expect(r.$2.left, closeTo(x0[r.$1]!, 1));
    }

    // 显示区域缩小到 1/4：超出范围的行去掉，留下的都在上面 1/4
    await tester.pumpWidget(build(const DanmakuConfig(area: 0.25, fontSize: 48, speed: 6)));
    await tester.pump(const Duration(milliseconds: 16));
    final rects = layer.debugRects;
    expect(rects, isNotEmpty);
    expect(rects.length, lessThan(before.length));
    for (final r in rects) {
      expect(r.$2.bottom, lessThanOrEqualTo(1080 * 0.25 + 16 + 1));
    }
  });
}
