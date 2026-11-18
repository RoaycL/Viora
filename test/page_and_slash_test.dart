import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/input/intents.dart';

void main() {
  Widget host({required List<Widget> children, VoidCallback? onSearch}) => MaterialApp(
    shortcuts: {...WidgetsApp.defaultShortcuts, ...appShortcuts},
    actions: {
      ...WidgetsApp.defaultActions,
      SlashSearchIntent: SlashSearchAction(onSearch ?? () {}),
      PageIntent: PageAction(),
    },
    home: Scaffold(body: ListView(children: children)),
  );

  testWidgets('频道 + / -、PageDown / PageUp：焦点一次移动 3 行', (tester) async {
    final nodes = [for (var i = 0; i < 10; i++) FocusNode(debugLabel: 'row $i')];
    addTearDown(() {
      for (final n in nodes) {
        n.dispose();
      }
    });
    await tester.pumpWidget(
      host(
        children: [for (final n in nodes) Focus(focusNode: n, child: const SizedBox(height: 60))],
      ),
    );
    nodes[0].requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.channelDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, nodes[3]);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, nodes[6]);
    await tester.sendKeyEvent(LogicalKeyboardKey.channelUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, nodes[3]);
  });

  testWidgets('/ 打开搜索；焦点在输入框里时照常输入 /', (tester) async {
    var searched = 0;
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final button = FocusNode();
    addTearDown(button.dispose);
    await tester.pumpWidget(
      host(
        onSearch: () => searched++,
        children: [
          Focus(focusNode: button, child: const SizedBox(height: 60)),
          TextField(controller: controller),
        ],
      ),
    );
    button.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    expect(searched, 1);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    expect(searched, 1, reason: '输入框里不触发搜索');
  });
}
