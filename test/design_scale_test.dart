import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/ui/scale/design_scale.dart';

void main() {
  testWidgets('拖动窗口时冻结布局，停下后再按新尺寸布局；单次改变直接生效', (tester) async {
    var builds = 0;
    Size? seen;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      DesignScale(
        child: Builder(
          builder: (context) {
            builds++;
            seen = MediaQuery.sizeOf(context);
            return const SizedBox.expand();
          },
        ),
      ),
    );
    expect(seen, const Size(1920, 1080));

    // 单次改变（如最大化 / 还原）：直接重新布局
    tester.view.physicalSize = const Size(1600, 1000);
    await tester.pump();
    expect(seen!.width, 1920);
    expect(seen!.height, closeTo(1200, 0.01));
    final afterFirst = builds;

    // 紧接着连续改变（拖动边框）：子树不重建，画布尺寸保持不变
    for (final w in [1500.0, 1400.0, 1300.0]) {
      tester.view.physicalSize = Size(w, 1000);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(builds, afterFirst);
    expect(seen!.height, closeTo(1200, 0.01));

    // 停下后按最终尺寸重新布局
    await tester.pump(const Duration(milliseconds: 300));
    expect(seen!.height, closeTo(1000 * 1920 / 1300, 0.01));
  });
}
