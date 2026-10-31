import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/platform_profile.dart';
import 'package:viora/ui/nav/side_nav_rail.dart';
import 'package:viora/ui/nav/top_tab_bar.dart';

import 'focus_navigation_test.dart' show focused, press, pumpApp, unmount;

/// 电视的顶部标签栏（Windows 的左侧导航栏见 focus_navigation_test.dart）
void main() {
  setUp(() => PlatformProfile.debugOverride = PlatformProfile.tv);
  tearDown(() => PlatformProfile.debugOverride = PlatformProfile.desktop);

  bool barVisible(WidgetTester tester) => tester.widget<TopTabBar>(find.byType(TopTabBar)).visible;

  testWidgets('电视没有左侧导航栏；第一行按 ↑ 进入标签栏，←→ 切换，↓ 回到原来的位置', (tester) async {
    await pumpApp(tester);
    expect(find.byType(SideNavRail), findsNothing);
    expect(find.byType(TopTabBar), findsOneWidget);
    expect(focused, 'hero#0');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused, 'nav:/');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused, 'nav:/library');
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused, 'nav:/');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'hero#0');
    await unmount(tester);
  });

  testWidgets('电视最左侧按 ← 停住，不进入导航；往下翻时标签栏滑出，回到第一行再出现', (tester) async {
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'row3#0');
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused, 'row3#0');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'row4#0');
    expect(barVisible(tester), isFalse);
    // 不在第一行时 ↑ 只是回到上一行
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused, 'hero#0');
    expect(barVisible(tester), isTrue);
    await unmount(tester);
  });

  testWidgets('电视返回键：一级页面先回到标签栏，再按回首页；首页在标签栏上按返回提示退出', (tester) async {
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused, 'nav:/library');
    await press(tester, LogicalKeyboardKey.select);
    expect(find.text('还没有媒体服务器'), findsOneWidget);
    expect(focused, 'VFocusable');
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused, 'nav:/library');
    expect(find.text('还没有媒体服务器'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('时光代理人'), findsWidgets);
    expect(focused, 'hero#0');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused, 'nav:/');
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('再按一次返回键退出 Viora'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await unmount(tester);
  });

  testWidgets('电视设置页（不是按行导航的页面）最上面按 ↑ 也进入标签栏', (tester) async {
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowUp);
    for (var i = 0; i < 4; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focused, 'nav:/settings');
    await press(tester, LogicalKeyboardKey.select);
    expect(focused, isNot(startsWith('nav:')));
    for (var i = 0; i < 10 && !(focused ?? '').startsWith('nav:'); i++) {
      await press(tester, LogicalKeyboardKey.arrowUp);
    }
    expect(focused, 'nav:/settings');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, isNot(startsWith('nav:')));
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('电视搜索不占标签，在右上角：在「设置」上按 → 到搜索图标，OK 打开搜索页', (tester) async {
    await pumpApp(tester);
    expect(find.text('搜索'), findsNothing);
    await press(tester, LogicalKeyboardKey.arrowUp);
    for (var i = 0; i < 5; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focused, 'nav:/search');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused, 'nav:/search');
    await press(tester, LogicalKeyboardKey.select);
    expect(focused, isNot(startsWith('nav:')));
    await press(tester, LogicalKeyboardKey.escape);
    expect(focused, 'nav:/search');
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('电视一次返回只退一步：按键处理过的返回，紧接着到的系统返回（松开按键时转来的）被丢掉', (tester) async {
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.select);
    expect(find.text('还没有媒体服务器'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(focused, 'nav:/library');
    expect(find.text('还没有媒体服务器'), findsOneWidget);
    // 单独到达的系统返回照常处理（标签栏上返回 → 回首页）
    await tester.pump(const Duration(milliseconds: 400));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('时光代理人'), findsWidgets);
    await unmount(tester);
  });

  testWidgets('电视标签停留一会儿就切到那个页面，焦点留在标签上；快速划过的不切；搜索仍要按 OK', (tester) async {
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('还没有媒体服务器'), findsOneWidget);
    expect(focused, 'nav:/library');
    // 快速划过「收藏」到「观看记录」：只打开最后停下的那个
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('还没有观看记录'), findsOneWidget);
    expect(focused, 'nav:/history');
    // 回到首页：首页的播放按钮会自动聚焦，浏览标签时不能抢走焦点
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    }
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('时光代理人'), findsWidgets);
    expect(focused, 'nav:/');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'hero#0');
    // 搜索图标停留不切页面
    await press(tester, LogicalKeyboardKey.arrowUp);
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(focused, 'nav:/search');
    expect(find.text('时光代理人'), findsWidgets);
    await unmount(tester);
  });
}
