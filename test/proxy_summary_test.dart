import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/app/app.dart';
import 'package:viora/data/config/config_store.dart';

import 'focus_navigation_test.dart' show pumpApp, unmount;

/// 反向代理统一在「设置 → 接口与网络 → 反向代理」里设置，其他地方不再有单独的开关
void main() {
  testWidgets('反向代理汇总：列出 TMDB / 评分 / 片头片尾 / 更新 / 服务器线路，没填地址时打不开', (tester) async {
    SharedPreferences.setMockInitialValues({});
    ConfigStore.vault = MemoryVault();
    await pumpApp(tester);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('接口与网络'));
    await tester.pumpAndSettle();
    expect(find.text('经过反向代理的服务'), findsOneWidget);
    for (final label in ['TMDB', '外部评分', '片头片尾数据库']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // 「应用更新」既是汇总里的一项，也是下面更新设置的小标题
    expect(find.text('应用更新'), findsNWidgets(2));
    // 原来分散在各处的开关已经去掉
    expect(find.text('通过反向代理访问 TMDB'), findsNothing);
    expect(find.text('通过反向代理访问评分服务'), findsNothing);
    expect(find.text('通过反向代理检查和下载更新'), findsNothing);
    expect(find.text('通过反向代理访问'), findsNothing);

    final container = ProviderScope.containerOf(tester.element(find.byType(VioraApp)));
    await tester.tap(find.text('TMDB'));
    await tester.pumpAndSettle();
    expect(find.text('请先填写上面的反向代理地址'), findsOneWidget);
    expect(container.read(configProvider).tmdb.useProxy, isFalse);

    await tester.enterText(find.byType(TextField).first, 'https://proxy.example.com/proxy/');
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('TMDB'));
    await tester.pumpAndSettle();
    expect(container.read(configProvider).tmdb.useProxy, isTrue);
    await tester.pump(const Duration(seconds: 5));
    await unmount(tester);
  });
}
