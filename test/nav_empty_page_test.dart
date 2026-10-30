import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/platform_profile.dart';

import 'focus_navigation_test.dart' show focused, press, pumpApp, unmount;

/// 切到还没有可聚焦内容的页面（加载中 / 空列表）时，导航不能被卡住
void main() {
  tearDown(() => PlatformProfile.debugOverride = PlatformProfile.desktop);

  testWidgets('Windows：打开没有内容的收藏页后，焦点留在导航上，可以继续切换', (tester) async {
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused, 'nav:/');
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'nav:/favorites');
    await press(tester, LogicalKeyboardKey.select);
    expect(find.text('收藏'), findsWidgets);
    expect(focused, 'nav:/favorites');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'nav:/history');
    await press(tester, LogicalKeyboardKey.select);
    expect(focused, 'nav:/history');
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.select);
    expect(focused, 'hero#0');
    await unmount(tester);
  });

  testWidgets('焦点已经落在没有内容的页面上时，方向键仍能回到导航', (tester) async {
    PlatformProfile.debugOverride = PlatformProfile.tv;
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused, 'nav:/favorites');
    await press(tester, LogicalKeyboardKey.select);
    // 页面没有可聚焦的内容时按 ↓：焦点进不去，留在标签上
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'nav:/favorites');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused, 'nav:/history');
    await unmount(tester);
  });
}
