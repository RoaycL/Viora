import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/platform_profile.dart';
import 'package:viora/ui/focus/row_focus.dart';
import 'package:viora/ui/rows/focus_row.dart';

void main() {
  for (final profile in PlatformProfile.values) {
    testWidgets('${profile.name}：横向滚动时新进入画面的卡片浮现（电视不做动画）', (tester) async {
      PlatformProfile.debugOverride = profile;
      addTearDown(() => PlatformProfile.debugOverride = PlatformProfile.desktop);
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: RowFocusScope(
              child: FocusRow(
                rowIndex: 0,
                itemCount: 20,
                itemExtent: 220,
                height: 300,
                itemBuilder: (context, i, node) => Focus(focusNode: node, child: Text('卡片 $i')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      double opacityOf(int i) {
        final o = find.ancestor(of: find.text('卡片 $i'), matching: find.byType(Opacity));
        return o.evaluate().isEmpty ? 1 : tester.widget<Opacity>(o.first).opacity;
      }

      // 打开时就在画面里的直接显示
      expect(opacityOf(0), 1);
      final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
      list.position.jumpTo(1600);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      if (profile == PlatformProfile.desktop) {
        expect(opacityOf(12), lessThan(1), reason: '正在浮现');
      }
      await tester.pumpAndSettle();
      expect(opacityOf(12), 1);
      expect(opacityOf(10), 1);
    });
  }

  testWidgets('电视关掉低配模式：和 Windows 一样有浮现动画', (tester) async {
    PlatformProfile.debugOverride = PlatformProfile.tv;
    PerfMode.debugLite = false;
    addTearDown(() {
      PlatformProfile.debugOverride = PlatformProfile.desktop;
      PerfMode.debugLite = true;
    });
    expect(PerfMode.lite, isFalse);
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: RowFocusScope(
            child: FocusRow(
              rowIndex: 0,
              itemCount: 20,
              itemExtent: 220,
              height: 300,
              itemBuilder: (context, i, node) => Focus(focusNode: node, child: Text('卡片 $i')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
    list.position.jumpTo(1600);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final o = find.ancestor(of: find.text('卡片 12'), matching: find.byType(Opacity));
    expect(tester.widget<Opacity>(o.first).opacity, lessThan(1));
    await tester.pumpAndSettle();

    // 低配模式：电视上没有浮现动画
    PerfMode.debugLite = true;
    expect(PerfMode.lite, isTrue);
  });
}
