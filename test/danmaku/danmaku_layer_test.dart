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
}
