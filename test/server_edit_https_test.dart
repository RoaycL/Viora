import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/features/library/server_edit_page.dart';
import 'package:viora/ui/widgets/form.dart';

void main() {
  testWidgets('添加服务器：HTTPS 开关默认关；输入带 https:// 的地址时自动打开', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: Scaffold(body: ServerEditPage()))));
    await tester.pump();

    VToggle httpsToggle() => tester.widget<VToggle>(find.widgetWithText(VToggle, '使用 HTTPS'));
    expect(httpsToggle().value, isFalse);
    expect(find.textContaining('所有线路使用 http://'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'https://emby.example.com:8920');
    await tester.pump();
    expect(httpsToggle().value, isTrue);
    expect(find.textContaining('所有线路使用 https://'), findsOneWidget);

    // 手动关掉
    httpsToggle().onChanged(false);
    await tester.pump();
    expect(httpsToggle().value, isFalse);
  });
}
