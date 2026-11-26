import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/ui/nav/side_nav_rail.dart';

class _Config extends ConfigStore {
  @override
  AppConfig build() => const AppConfig();
}

void main() {
  testWidgets('撑满高度的导航栏：没有固定服务器时「设置」贴在最下面，不停在中间', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final nodes = {for (final i in NavItem.values) i.path: FocusNode()};
    final scope = FocusScopeNode();
    addTearDown(() {
      for (final n in nodes.values) {
        n.dispose();
      }
      scope.dispose();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [configProvider.overrideWith(_Config.new)],
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                height: 900,
                child: FocusScope(
                  node: scope,
                  child: SideNavRail(active: NavItem.home, nodes: nodes, scope: scope, onSelect: (_) {}),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final rail = tester.getRect(find.byType(SideNavRail));
    final settings = tester.getRect(find.byIcon(NavItem.settings.icon));
    expect(rail.bottom - settings.bottom, lessThan(150)); // 修复前和固定服务器区平分剩余空间，离底部约 220
  });
}
