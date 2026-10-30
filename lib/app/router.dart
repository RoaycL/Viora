import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/browse/server_page.dart';
import '../features/collections/collections_pages.dart';
import '../features/detail/item_detail_page.dart';
import '../features/home/home_page.dart';
import '../features/library/library_page.dart';
import '../features/library/server_edit_page.dart';
import '../features/player/player_page.dart';
import '../features/search/search_page.dart';
import '../features/settings/settings_page.dart';
import '../features/tmdb/tmdb_detail_page.dart';
import '../features/tmdb/tmdb_grid_page.dart';
import 'shell.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');

GoRouter buildRouter({List<NavigatorObserver>? observers}) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    observers: observers,
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(location: state.uri.path, child: child),
        routes: [
          _tab('/', const HomePage()),
          _tab('/library', const LibraryPage()),
          GoRoute(
            path: '/library/add',
            pageBuilder: (context, state) => NoTransitionPage<void>(key: state.pageKey, child: const ServerEditPage()),
          ),
          GoRoute(
            path: '/library/edit/:sid',
            pageBuilder: (context, state) => NoTransitionPage<void>(
              key: state.pageKey,
              child: ServerEditPage(serverId: state.pathParameters['sid']),
            ),
          ),
          GoRoute(
            path: '/library/server/:sid',
            pageBuilder: (context, state) => NoTransitionPage<void>(
              key: state.pageKey,
              child: ServerPage(serverId: state.pathParameters['sid']!),
            ),
          ),
          GoRoute(
            path: '/library/server/:sid/lib/:lid',
            pageBuilder: (context, state) => NoTransitionPage<void>(
              key: state.pageKey,
              child: LibraryGridPage(
                serverId: state.pathParameters['sid']!,
                libraryId: state.pathParameters['lid']!,
                title: state.uri.queryParameters['name'] ?? '媒体库',
              ),
            ),
          ),
          GoRoute(
            path: '/search',
            pageBuilder: (context, state) {
              final q = state.uri.queryParameters['q'] ?? '';
              return NoTransitionPage<void>(
                key: state.pageKey,
                child: SearchPage(key: ValueKey(q), initialQuery: q),
              );
            },
          ),
          _tab('/favorites', const FavoritesPage()),
          _tab('/history', const HistoryPage()),
          _tab('/settings', const SettingsPage()),
        ],
      ),
      GoRoute(
        path: '/item/:sid/:id',
        pageBuilder: (context, state) => CustomTransitionPage<void>(
          key: state.pageKey,
          child: ItemDetailPage(serverId: state.pathParameters['sid']!, itemId: state.pathParameters['id']!),
          transitionsBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
        ),
      ),
      GoRoute(
        path: '/play/:sid/:id',
        pageBuilder: (context, state) => CustomTransitionPage<void>(
          key: state.pageKey,
          child: PlayerPage(
            serverId: state.pathParameters['sid']!,
            itemId: state.pathParameters['id']!,
            startMs: int.tryParse(state.uri.queryParameters['pos'] ?? '') ?? 0,
            sourceId: state.uri.queryParameters['source'],
            triedSources: [
              for (final t in (state.uri.queryParameters['tried'] ?? '').split(','))
                if (t.isNotEmpty) t,
            ],
          ),
          transitionsBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
        ),
      ),
      GoRoute(
        path: '/tmdb/:type/:id',
        pageBuilder: (context, state) {
          final type = state.pathParameters['type']!;
          final id = int.tryParse(state.pathParameters['id']!) ?? 0;
          return CustomTransitionPage<void>(
            key: state.pageKey,
            child: switch (type) {
              'person' => TmdbPersonPage(id: id),
              'network' => TmdbNetworkPage(id: id, name: state.uri.queryParameters['name'] ?? '播出平台'),
              _ => TmdbDetailPage(isTv: type == 'tv', id: id),
            },
            transitionsBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
          );
        },
      ),
    ],
  );
}

GoRoute _tab(String path, Widget page) => GoRoute(
  path: path,
  pageBuilder: (context, state) => NoTransitionPage<void>(key: state.pageKey, child: page),
);
