import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/app/platform_profile.dart';
import 'package:viora/app/theme.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/data/index/index_sync.dart';
import 'package:viora/data/index/media_index.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/features/search/search_page.dart';

const server = ServerConfig(
  id: 's',
  name: 's',
  type: ServerType.emby,
  username: 'u',
  userId: 'u',
  token: 't',
  lines: [],
);

class OneServer extends ConfigStore {
  @override
  AppConfig build() => const AppConfig(servers: [server]);
}

void main() {
  testWidgets('Windows 搜索页：回车搜索、按类型筛选；搜过的进「最近搜索」，点一下再搜', (tester) async {
    PlatformProfile.debugOverride = PlatformProfile.desktop;
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(2240, 1260);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final index = (await tester.runAsync(() => MediaIndex.open(path: ':memory:')))!;
    index.bindAccounts({'s': 'acc'});
    index.upsert('s', [
      for (var i = 0; i < 6; i++)
        MediaItem(serverId: 's', id: 'm$i', kind: i < 4 ? MediaKind.series : MediaKind.movie, name: '时光代理人 $i'),
    ]);
    Future<void> settle() async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 400));
      }
    }

    Widget app() => ProviderScope(
      overrides: [configProvider.overrideWith(OneServer.new), mediaIndexProvider.overrideWith((ref) async => index)],
      child: MaterialApp(
        theme: buildTheme(),
        home: const Scaffold(body: SearchPage()),
      ),
    );
    await tester.pumpWidget(app());
    await settle();
    expect(find.text('想看什么？'), findsOneWidget, reason: '没有最近搜索时的提示');

    await tester.enterText(find.byType(TextField), '时光');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle();
    expect(find.text('6 部作品'), findsOneWidget);
    await tester.tap(find.text('电影 2'));
    await tester.pump();
    expect(find.text('时光代理人 4'), findsOneWidget);
    expect(find.text('时光代理人 0'), findsNothing);

    // 重新打开搜索页：最近搜索里有「时光」，点一下直接搜
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await settle();
    expect(find.text('最近搜索'), findsOneWidget);
    await tester.tap(find.text('时光'));
    await settle();
    expect(find.text('6 部作品'), findsOneWidget);
    PlatformProfile.debugOverride = PlatformProfile.desktop;
  });
}
