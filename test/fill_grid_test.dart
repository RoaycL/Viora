import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/ui/widgets/fill_grid.dart';

void main() {
  testWidgets('自适应网格：卡片等比放大铺满整行，右侧不留大片空白', (tester) async {
    tester.view.physicalSize = const Size(2400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<double> lastRight(double width) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: FillGrid(
                itemWidth: 400,
                children: [for (var i = 0; i < 12; i++) SizedBox(key: ValueKey(i), height: 100)],
              ),
            ),
          ),
        ),
      );
      // 第一行最后一张卡片的右边缘
      final rects = [for (var i = 0; i < 12; i++) tester.getRect(find.byKey(ValueKey(i)))];
      final firstRow = rects.where((r) => r.top == rects.first.top);
      return firstRow.map((r) => r.right).reduce((a, b) => a > b ? a : b);
    }

    for (final w in [1000.0, 1500.0, 2100.0]) {
      expect(await lastRight(w), closeTo(w, 1), reason: '宽度 $w');
    }
  });
}
