import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/app/desktop_prefs.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/ui/nav/side_nav_rail.dart';

final _many = [
  for (var i = 0; i < 12; i++)
    ServerConfig(
      id: 's$i',
      type: ServerType.emby,
      name: 'S$i',
      username: 'u',
      lines: [ServerLine(id: 'l', name: 'l', url: 'http://127.0.0.1:$i')],
    ),
];

class _Config extends ConfigStore {
  @override
  AppConfig build() => AppConfig(servers: _many);
}

Future<void> _pump(WidgetTester tester, double height) async {
  tester.view.physicalSize = Size(400, height);
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
              height: height,
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
}

void main() {
  testWidgets('撑满高度的导航栏：没有固定服务器时「设置」贴在最下面，不停在中间', (tester) async {
    DesktopPrefs.instance.pinnedServers.value = const [];
    await _pump(tester, 900);
    final rail = tester.getRect(find.byType(SideNavRail));
    final settings = tester.getRect(find.byIcon(NavItem.settings.icon));
    expect(rail.bottom - settings.bottom, lessThan(150)); // 修复前和固定服务器区平分剩余空间，离底部约 220
  });

  testWidgets('固定的服务器多了：「设置」仍固定在最下面、和服务器不重叠，多出来的服务器可以滚动', (tester) async {
    DesktopPrefs.instance.pinnedServers.value = [for (final s in _many) s.id];
    addTearDown(() => DesktopPrefs.instance.pinnedServers.value = const []);
    await _pump(tester, 700);
    final rail = tester.getRect(find.byType(SideNavRail));
    final settings = tester.getRect(find.byIcon(NavItem.settings.icon));
    expect(rail.bottom - settings.bottom, lessThan(150));
    final scroll = find.byType(SingleChildScrollView);
    final viewport = tester.getRect(scroll);
    // 服务器区域在「设置」上面结束，超出的部分被裁掉，不会画到设置上
    expect(viewport.bottom, lessThan(settings.top));
    final position = tester
        .state<ScrollableState>(find.descendant(of: scroll, matching: find.byType(Scrollable)))
        .position;
    expect(position.maxScrollExtent, greaterThan(0));
    await tester.drag(scroll, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    // 「设置」不跟着滚动
    expect(tester.getRect(find.byIcon(NavItem.settings.icon)), settings);
  });

  testWidgets('长按侧边栏的服务器进入编辑：图标出现移除按钮，点一下就从侧边栏移除；点「完成」退出', (tester) async {
    SharedPreferences.setMockInitialValues({});
    DesktopPrefs.instance.pinnedServers.value = ['s0', 's1', 's2'];
    addTearDown(() => DesktopPrefs.instance.pinnedServers.value = const []);
    await _pump(tester, 900);
    final remove = find.byKey(const ValueKey('nav-server-remove'));
    expect(remove, findsNothing);
    await tester.longPress(find.bySemanticsLabel('S1'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(remove, findsNWidgets(3));
    await tester.tap(remove.at(1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(DesktopPrefs.instance.pinnedServers.value, ['s0', 's2']);
    expect(remove, findsNWidgets(2));
    await tester.tap(find.text('完成'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(remove, findsNothing);
    expect(find.text('完成'), findsNothing);
  });
}
