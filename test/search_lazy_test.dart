import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/app.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/index/index_sync.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/data/media/server_registry.dart';
import 'package:viora/ui/rows/cards.dart';

import 'focus_navigation_test.dart' show tmdbFixtures, unmount;
import 'nav_empty_page_test.dart' show OneServer;

/// 一台服务器搜索返回 60 部
class SearchClient extends EmbyClient {
  SearchClient(ServerConfig server)
    : super(
        config: AppConfig(servers: [server]),
        server: server,
        appVersion: 'test',
      );

  @override
  Future<PagedItems> items({
    String? parentId,
    String types = 'Movie,Series',
    int start = 0,
    int limit = 60,
    String sortBy = 'DateCreated,SortName',
    String sortOrder = 'Descending',
    String? searchTerm,
    DateTime? minDateLastSaved,
    String? filters,
    String? fields,
    bool userData = true,
  }) async => PagedItems([
    for (var i = 0; i < 60; i++) MediaItem(serverId: 's', id: 'm$i', name: '测试电影 $i', kind: MediaKind.movie),
  ], 60);
}

void main() {
  testWidgets('搜索结果懒加载：60 部结果只构建屏幕附近的卡片（不一次全建、全去下载海报和补中文标题）', (tester) async {
    autoCheckUpdatesOnLaunch = false;
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...tmdbFixtures,
          configProvider.overrideWith(OneServer.new),
          serverClientProvider.overrideWith((ref, id) => SearchClient(ref.read(configProvider).server(id)!)),
          mediaIndexProvider.overrideWith((ref) async => null),
        ],
        child: const VioraApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '测试');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('共 60 部作品'), findsOneWidget);
    final built = find.byType(PosterCard).evaluate().length;
    expect(built, greaterThan(0));
    expect(built, lessThan(60));
    await unmount(tester);
  });
}
