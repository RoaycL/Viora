import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/ui/widgets/fill_grid.dart';

void main() {
  testWidgets('懒加载网格：500 个条目只建屏幕附近的几行，滚到底能看到最后一个', (tester) async {
    var built = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CustomScrollView(
          slivers: [
            SliverFillGrid(
              itemWidth: 200,
              itemCount: 500,
              itemBuilder: (context, i) {
                built++;
                return SizedBox(height: 300, child: Text('item $i'));
              },
            ),
          ],
        ),
      ),
    );
    expect(built, lessThan(100));
    expect(find.text('item 0'), findsOneWidget);
    await tester.dragUntilVisible(find.text('item 499'), find.byType(CustomScrollView), const Offset(0, -3000));
    expect(find.text('item 499'), findsOneWidget);
  });
}
