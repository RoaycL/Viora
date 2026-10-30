import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/platform_profile.dart';

import 'focus_navigation_test.dart' show pumpApp, unmount;

void main() {
  setUp(() => PlatformProfile.debugOverride = PlatformProfile.tv);
  tearDown(() => PlatformProfile.debugOverride = PlatformProfile.desktop);

  List<String> recordExits(WidgetTester tester) {
    final exits = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') exits.add('pop');
      return null;
    });
    return exits;
  }

  testWidgets('电视：首页按一次返回只提示，2 秒内再按一次才退出', (tester) async {
    final exits = recordExits(tester);
    await pumpApp(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('再按一次返回键退出 Viora'), findsOneWidget);
    expect(exits, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(exits, ['pop']);
    await tester.pump(const Duration(seconds: 5));
    await unmount(tester);
  });

  testWidgets('电视：两次返回间隔超过 2 秒不退出，重新开始计时', (tester) async {
    final exits = recordExits(tester);
    await pumpApp(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 3));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(exits, isEmpty);
    expect(find.text('再按一次返回键退出 Viora'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await unmount(tester);
  });

  testWidgets('电视：按住返回键不放不会连续触发退出；系统返回同样需要连按两次', (tester) async {
    final exits = recordExits(tester);
    await pumpApp(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    for (var i = 0; i < 10; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(exits, isEmpty);
    await tester.pump(const Duration(seconds: 3));
    // 系统层面的返回（没被按键处理的返回键 / 返回手势）
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pump();
    expect(exits, isEmpty);
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pump();
    expect(exits, ['pop']);
    await tester.pump(const Duration(seconds: 5));
    await unmount(tester);
  });
}
