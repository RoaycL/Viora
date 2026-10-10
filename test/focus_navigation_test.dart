import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/app.dart';
import 'package:viora/app/input/intents.dart';

String? get focused => FocusManager.instance.primaryFocus?.debugLabel;

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

Future<void> pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const ProviderScope(child: VioraApp()));
  await tester.pumpAndSettle();
}

/// 卸载应用，停止轮播 / 时钟等周期计时器。
Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  test('遥控器返回键、Esc、手柄 B 都映射为返回意图', () {
    for (final key in [LogicalKeyboardKey.goBack, LogicalKeyboardKey.escape, LogicalKeyboardKey.gameButtonB]) {
      final intent = appShortcuts.entries
          .where((e) => e.key is SingleActivator && (e.key as SingleActivator).trigger == key)
          .map((e) => e.value)
          .single;
      expect(intent, isA<BackIntent>());
    }
  });

  testWidgets('启动后焦点在 Hero 的播放按钮', (tester) async {
    await pumpApp(tester);
    expect(focused, 'hero#0');
    expect(find.text('时光代理人'), findsWidgets);
    await unmount(tester);
  });

  testWidgets('上下切换行时恢复每行上次的位置（行记忆）', (tester) async {
    await pumpApp(tester);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'row1#0');

    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused, 'row1#2');

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'row2#0');

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused, 'row1#2');

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused, 'hero#0');
    await unmount(tester);
  });

  testWidgets('行尾按 → 不移动焦点', (tester) async {
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.pumpAndSettle();
    expect(focused, 'row1#5');
    await unmount(tester);
  });

  testWidgets('最左侧按 ← 进入导航栏当前项，按 → 回到原来的位置', (tester) async {
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused, 'row1#1');

    await press(tester, LogicalKeyboardKey.arrowLeft);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused, 'nav:/');

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused, 'row1#0');
    await unmount(tester);
  });

  testWidgets('返回键：先回到页面顶部的 Hero', (tester) async {
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'row2#0');

    await press(tester, LogicalKeyboardKey.escape);
    expect(focused, 'hero#0');
    await unmount(tester);
  });

  testWidgets('在导航栏选择资源库后进入资源库并聚焦第一张卡片', (tester) async {
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused, 'nav:/');

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'nav:/library');

    await press(tester, LogicalKeyboardKey.select);
    expect(find.text('资源库'), findsWidgets);
    expect(find.text('私服'), findsOneWidget);
    expect(focused, 'VFocusable');

    // 返回键（键盘 Esc）回到首页
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('继续观看'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('从卡片打开详情页，返回键回到首页', (tester) async {
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.select);
    expect(find.text('按返回键回到上一页'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('按返回键回到上一页'), findsNothing);
    expect(focused, 'row2#0');
    await unmount(tester);
  });
}
