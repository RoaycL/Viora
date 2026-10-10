import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/app/theme.dart';
import 'package:viora/domain/models/segment_settings.dart';
import 'package:viora/features/segments/segment_service.dart';
import 'package:viora/features/segments/segment_settings_page.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<ProviderContainer> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(),
          home: const Scaffold(body: SegmentSettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('skip modes update persisted preferences from the settings UI', (tester) async {
    final container = await open(tester);
    expect(find.text('片头片尾与前情提要'), findsOneWidget);
    await tester.tap(find.text('显示按钮').first);
    await tester.pumpAndSettle();
    expect(container.read(segmentSettingsProvider).requireValue.intro, SegmentSkipMode.off);
    await tester.tap(find.text('关闭').first);
    await tester.pumpAndSettle();
    expect(container.read(segmentSettingsProvider).requireValue.intro, SegmentSkipMode.auto);
    expect(container.read(segmentSettingsProvider).requireValue.recap, SegmentSkipMode.button);
  });

  testWidgets('PublicMetaDB credentials are masked and can enable its provider', (tester) async {
    final container = await open(tester);
    await tester.ensureVisible(find.text('配置').last);
    await tester.tap(find.text('配置').last);
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(2));
    final textField = tester.widget<TextField>(find.byType(TextField).last);
    expect(textField.obscureText, isTrue);
    await tester.enterText(fields.last, 'test-pmdb-key');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(container.read(segmentSettingsProvider).requireValue.providers.last.apiKey, 'test-pmdb-key');
    await tester.ensureVisible(find.text('已关闭'));
    await tester.tap(find.text('已关闭'));
    await tester.pumpAndSettle();
    expect(container.read(segmentSettingsProvider).requireValue.providers.last.enabled, isTrue);
  });

  testWidgets('query requires media identity and actual file duration', (tester) async {
    await open(tester);
    await tester.ensureVisible(find.text('查询跳过片段'));
    await tester.tap(find.text('查询跳过片段'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查询'));
    await tester.pumpAndSettle();
    expect(find.text('至少填写一个作品 ID'), findsOneWidget);
    expect(find.text('请输入实际文件时长'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });
}
