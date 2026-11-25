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

  testWidgets('窄窗口不再继续缩小：保持最小缩放，画布变窄', (tester) async {
    Size? seen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget app() => DesignScale(
      designWidth: 2240,
      minScale: 0.6,
      child: Builder(
        builder: (context) {
          seen = MediaQuery.sizeOf(context);
          return const SizedBox.expand();
        },
      ),
    );
    tester.view.physicalSize = const Size(1920, 1080);
    await tester.pumpWidget(app());
    expect(seen!.width, 2240);
    tester.view.physicalSize = const Size(960, 540);
    await tester.pump(const Duration(seconds: 1));
    expect(seen!.width, closeTo(1600, 0.01));
    expect(seen!.height, closeTo(900, 0.01));
  });

  testWidgets('最小缩放下拖动窗口：冻结的快照按当前窗口宽度缩放，正好铺满不被裁掉', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(1200, 700);
    await tester.pumpWidget(const DesignScale(designWidth: 2240, minScale: 0.6, child: SizedBox.expand()));
    // 单次改变到 1200 宽：缩放 0.6，画布 2000 宽
    tester.view.physicalSize = const Size(1200, 675);
    await tester.pump(const Duration(seconds: 1));
    // 画面在窗口里实际占的宽度
    double shown() => tester.getRect(find.byType(SizedBox).last).width;
    expect(shown(), closeTo(1200, 0.01));
    // 连续拖窄到 960：画布冻结在 2000 宽，快照缩到 960 宽（不是按 0.6 画成 1200 宽再被裁掉）
    for (final w in [1100.0, 1000.0, 960.0]) {
      tester.view.physicalSize = Size(w, 675);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(shown(), closeTo(960, 0.01));
    // 停下后按最小缩放重新布局：画布变成 1600 宽，仍然铺满窗口
    await tester.pump(const Duration(milliseconds: 300));
    expect(shown(), closeTo(960, 0.01));
  });
}
