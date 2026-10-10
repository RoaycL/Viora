import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:viora/features/sync/sync_settings_section.dart';

void main() {
  testWidgets('接收配置窗口：开启接收，显示二维码和配对码；关闭后停止', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: TextButton(onPressed: () => showReceiveDialog(context, ref), child: const Text('打开')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // 真实开端口：在 runAsync 里等待
    for (var i = 0; i < 50 && find.text('正在开启…').evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(find.text('接收配置'), findsOneWidget);
    // 测试环境里可能没有局域网地址：有地址时显示二维码和配对码，没有时提示
    final hasQr = find.byType(QrImageView).evaluate().isNotEmpty;
    if (hasQr) {
      expect(find.text('配对码'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^\d{4}$')), findsOneWidget);
    } else {
      expect(find.textContaining('没有找到局域网地址'), findsOneWidget);
    }
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('接收配置'), findsNothing);
  });
}
