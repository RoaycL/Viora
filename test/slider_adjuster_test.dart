import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/features/player/slider_adjuster.dart';
import 'package:viora/player/mpv_engine.dart';

Future<void> _pump(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(1920, 1080);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(ProviderScope(child: MaterialApp(home: Scaffold(body: child))));
  await t.pump();
}

void main() {
  test('上移百分比和 sub-pos 换算', () {
    expect(SubtitleLift.fromPosition(100), 0);
    expect(SubtitleLift.fromPosition(88), 12);
    expect(SubtitleLift.fromPosition(120), 0);
    expect(SubtitleLift.toPosition(25), 75);
    expect(SubtitleLift.toPosition(99), 100 - SubtitleLift.max);
    expect(SubtitleLift.label(100), '默认');
    expect(SubtitleLift.label(70), '上移 30%');
  });

  test('字幕离底部的距离：每 1% = 画面高度的 1%', () {
    const size = Size(1920, 1080);
    expect(MpvSubtitleView.bottomOffset(size, 100), MpvSubtitleView.baseBottom);
    expect(MpvSubtitleView.bottomOffset(size, 90), MpvSubtitleView.baseBottom + 108);
  });

  test('延迟按 0.1 秒取整、限制范围、显示文字', () {
    final d = SliderSpec.subtitleDelay;
    expect(d.snap(0.1 + 0.2), 0.3);
    expect(d.snap(12), 10);
    expect(d.format(0), '不偏移');
    expect(d.format(-1.5), '提前 1.5 秒');
    expect(SliderSpec.danmakuShift.format(2.3), '延后 2.3 秒');
  });

  testWidgets('字幕位置：方向键调整、回车完成；预览框跟着移动', (t) async {
    final changes = <double>[];
    double? done;
    await _pump(
      t,
      SliderAdjuster(
        spec: SliderSpec.subtitleLift,
        value: 0,
        subtitleScale: 1,
        onChanged: changes.add,
        onDone: (v) => done = v,
      ),
    );
    final box = find.byKey(const ValueKey('subtitle-position-preview'));
    final before = t.getRect(box).bottom;

    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    expect(changes, [5, 6]);
    expect(find.text('上移 6%'), findsOneWidget);
    expect(before - t.getRect(box).bottom, closeTo(1080 * 0.06, 0.5));

    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    expect(changes.last, 0, reason: '不会低于默认位置');

    // 点滑块中间 = 30%
    await t.tapAt(t.getRect(find.byKey(const ValueKey('slider-adjuster-slider'))).center);
    await t.pump();
    expect(changes.last, 30);

    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(done, 30);
  });

  testWidgets('字幕延迟：滑块中间是 0，← 提前 0.1 秒，Esc 完成；没有预览框', (t) async {
    double? last;
    double? done;
    await _pump(
      t,
      SliderAdjuster(
        spec: SliderSpec.subtitleDelay,
        value: 0.5,
        onChanged: (v) => last = v,
        onDone: (v) => done = v,
      ),
    );
    expect(find.byKey(const ValueKey('subtitle-position-preview')), findsNothing);
    expect(find.text('推后 0.5 秒'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await t.pump();
    expect(last, closeTo(0.4, 1e-9));
    await t.tapAt(t.getRect(find.byKey(const ValueKey('slider-adjuster-slider'))).center);
    await t.pump();
    expect(last, 0);
    expect(find.text('不偏移'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(done, 0);
    await t.pump(const Duration(seconds: 1));
  });
}
