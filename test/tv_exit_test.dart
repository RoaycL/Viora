import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/platform_profile.dart';

import 'focus_navigation_test.dart' show pumpApp, unmount;

void main() {
  setUp(() => PlatformProfile.debugOverride = PlatformProfile.tv);
  tearDown(() => PlatformProfile.debugOverride = PlatformProfile.desktop);

  testWidgets('电视：首页短按返回不退出，只提示长按退出；系统返回也不关闭应用', (tester) async {
    final exits = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') exits.add('pop');
      return null;
    });
    await pumpApp(tester);
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 300));
    }
    // 系统层面的返回（没被按键处理的返回键 / 返回手势）
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pump();
    expect(exits, isEmpty);
    expect(find.text('长按返回键 3 秒可以退出 Viora'), findsOneWidget);
    expect(find.text('退出 Viora？'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await unmount(tester);
  });

  testWidgets('电视：长按返回键 3 秒弹出确认；取消不退出，确认才退出', (tester) async {
    final exits = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') exits.add('pop');
      return null;
    });
    await pumpApp(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    for (var i = 0; i < 31; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('退出 Viora？'), findsOneWidget);

    // 默认焦点在「取消」：OK 不会退出
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('退出 Viora？'), findsNothing);
    expect(exits, isEmpty);

    // 再长按一次，选「退出」
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 3));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(exits, ['pop']);
    await unmount(tester);
  });

  testWidgets('电视：按一下就松开不会弹出退出确认', (tester) async {
    await pumpApp(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('退出 Viora？'), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    await unmount(tester);
  });
}
