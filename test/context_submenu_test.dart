import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/platform_profile.dart';
import 'package:viora/ui/panels/context_menu.dart';

void main() {
  for (final profile in PlatformProfile.values) {
    testWidgets('${profile.name}：二级菜单打开时上一级仍显示；选完回到上一级并显示新值', (tester) async {
      PlatformProfile.debugOverride = profile;
      addTearDown(() => PlatformProfile.debugOverride = PlatformProfile.desktop);
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var opacity = 85;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showContextMenu(
                    context,
                    title: '弹幕',
                    actionsBuilder: () => [
                      MenuAction.submenu(
                        '不透明度 · $opacity%',
                        Icons.opacity,
                        title: '弹幕不透明度',
                        items: () => [
                          for (final v in const [40, 60, 85, 100])
                            MenuAction('$v%${v == opacity ? ' ✓' : ''}', Icons.chat, () => opacity = v),
                        ],
                      ),
                      MenuAction('关闭弹幕', Icons.close, () {}),
                    ],
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('不透明度 · 85%'));
      await tester.pumpAndSettle();
      // 两级同时显示，二级不盖住一级
      expect(find.text('弹幕不透明度'), findsOneWidget);
      expect(find.text('不透明度 · 85%'), findsOneWidget);
      final parent = tester.getRect(find.text('关闭弹幕'));
      final child = tester.getRect(find.text('100%'));
      expect(parent.overlaps(child), isFalse);

      await tester.tap(find.text('60%'));
      await tester.pumpAndSettle();
      expect(opacity, 60);
      expect(find.text('弹幕不透明度'), findsNothing);
      expect(find.text('不透明度 · 60%'), findsOneWidget, reason: '回到上一级，显示新值');

      // 返回关闭上一级
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('不透明度 · 60%'), findsNothing);
    });
  }
}
