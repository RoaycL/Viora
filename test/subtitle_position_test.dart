import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/features/player/subtitle_position_adjuster.dart';
import 'package:viora/player/mpv_engine.dart';

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

  testWidgets('方向键调整、回车完成；预览框跟着移动', (t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final changes = <int>[];
    int? done;
    await t.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SubtitlePositionAdjuster(
              position: 100,
              scale: 1,
              onChanged: changes.add,
              onDone: (v) => done = v,
            ),
          ),
        ),
      ),
    );
    await t.pump();
    final box = find.byKey(const ValueKey('subtitle-position-preview'));
    final before = t.getRect(box).bottom;

    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    expect(changes, [95, 94]);
    expect(find.text('上移 6%'), findsOneWidget);
    // 上移 6% = 画面高度的 6%
    expect(before - t.getRect(box).bottom, closeTo(1080 * 0.06, 0.5));

    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    expect(changes.last, 100, reason: '不会低于默认位置');

    // 点滑块中间 = 30%
    final slider = t.getRect(find.byKey(const ValueKey('subtitle-position-slider')));
    await t.tapAt(slider.center);
    await t.pump();
    expect(changes.last, 70);

    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(done, 70);
  });
}
