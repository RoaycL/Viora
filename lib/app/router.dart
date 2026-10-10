import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/common/placeholder_page.dart';
import '../features/detail/detail_page.dart';
import '../features/home/home_page.dart';
import '../features/library/library_page.dart';
import '../features/settings/settings_page.dart';
import 'shell.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');

GoRouter buildRouter() {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(location: state.uri.path, child: child),
        routes: [
          _tab('/', const HomePage()),
          _tab('/library', const LibraryPage()),
          _tab(
            '/search',
            const PlaceholderPage(
              title: '搜索',
              milestone: 'M3',
              description: '聚合搜索：本地索引 + TMDB + 各服务器实时搜索，拼音首字母键盘与语音输入。',
            ),
          ),
          _tab('/favorites', const PlaceholderPage(title: '收藏', milestone: 'M3', description: '跨服务器的统一收藏，按作品聚合。')),
          _tab(
            '/history',
            const PlaceholderPage(title: '观看记录', milestone: 'M3', description: '本地统一观看记录（按 TMDB ID 聚合），与各服务器进度同步。'),
          ),
          _tab('/settings', const SettingsPage()),
        ],
      ),
      GoRoute(
        path: '/detail/:id',
        pageBuilder: (context, state) => CustomTransitionPage<void>(
          key: state.pageKey,
          child: DetailPage(id: state.pathParameters['id']!),
          transitionsBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
        ),
      ),
    ],
  );
}

GoRoute _tab(String path, Widget page) => GoRoute(
  path: path,
  pageBuilder: (context, state) => NoTransitionPage<void>(key: state.pageKey, child: page),
);
