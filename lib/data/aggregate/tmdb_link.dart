import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/config_store.dart';
import '../index/index_sync.dart';
import '../index/media_index.dart';
import '../index/title_norm.dart';
import '../media/media_models.dart';
import '../media/server_registry.dart';
import '../tmdb/tmdb_models.dart';

typedef TmdbLinkKey = ({bool isTv, int id});

/// TMDB 条目在媒体库里的副本（按聚合索引的 TMDB ID 匹配；索引未就绪时为空）
final libraryCopiesProvider = Provider.family<List<MediaItem>, TmdbLinkKey>((ref, key) {
  ref.watch(indexRevisionProvider);
  final index = ref.watch(mediaIndexProvider).value;
  if (index == null) return const [];
  ref.watch(configProvider.select((c) => c.serversKey));
  final servers = {for (final s in ref.read(configProvider).servers) s.id};
  try {
    return index
        .byTmdb(key.isTv ? MediaKind.series : MediaKind.movie, '${key.id}')
        .where((c) => servers.contains(c.serverId))
        .toList();
  } catch (_) {
    return const [];
  }
});

TmdbLinkKey linkKeyOf(TmdbTitle t) => (isTv: t.isTv, id: t.id);

/// 最近入库：所有服务器合并，同一部作品只出现一次
final recentlyAddedProvider = Provider<List<AggregatedTitle>>((ref) {
  ref.watch(indexRevisionProvider);
  final index = ref.watch(mediaIndexProvider).value;
  if (index == null) return const [];
  ref.watch(configProvider.select((c) => c.serversKey));
  final servers = {for (final s in ref.read(configProvider).servers) s.id};
  try {
    return groupTitles(index.latest(limit: 60).where((c) => servers.contains(c.serverId))).take(24).toList();
  } catch (_) {
    return const [];
  }
});

/// TMDB 详情页要找的作品
typedef TmdbSearchKey = ({bool isTv, int id, String title, String? originalTitle, int? year});

TmdbSearchKey searchKeyOf(TmdbTitle t) =>
    (isTv: t.isTv, id: t.id, title: t.title, originalTitle: t.originalTitle, year: t.year);

/// 进入 TMDB 详情页时才做的聚合搜索：本地索引 + 到每台服务器按中文名 / 原名实时搜索，
/// 按 TMDB ID 匹配（服务器条目没有 TMDB ID 时按标题 + 年份 ±1）。首页、推荐行不触发（docs/04-aggregation.md §7）。
final tmdbLibrarySearchProvider = FutureProvider.autoDispose.family<List<MediaItem>, TmdbSearchKey>((ref, key) async {
  final found = <String, MediaItem>{
    for (final c in ref.read(libraryCopiesProvider((isTv: key.isTv, id: key.id)))) '${c.serverId}/${c.id}': c,
  };
  final kind = key.isTv ? MediaKind.series : MediaKind.movie;
  final names = {key.title, ?key.originalTitle}.map(normalizeTitle).where((n) => n.isNotEmpty).toSet();
  bool matches(MediaItem it) {
    if (it.kind != kind) return false;
    final tmdb = it.tmdbId?.trim();
    if (tmdb != null && tmdb.isNotEmpty) return tmdb == '${key.id}';
    final titles = {it.name, ?it.originalTitle}.map(normalizeTitle);
    if (!titles.any(names.contains)) return false;
    return key.year == null || it.year == null || (key.year! - it.year!).abs() <= 1;
  }

  final terms = {key.title, ?key.originalTitle}.where((t) => t.trim().isNotEmpty);
  await Future.wait([
    for (final s in ref.read(configProvider).servers)
      if (s.loggedIn)
        () async {
          final client = ref.read(serverClientProvider(s.id));
          if (client == null) return;
          for (final term in terms) {
            try {
              final page = await client
                  .items(searchTerm: term, types: key.isTv ? 'Series' : 'Movie', limit: 20)
                  .timeout(const Duration(seconds: 8));
              for (final it in page.items) {
                if (matches(it)) found['${it.serverId}/${it.id}'] = it;
              }
            } catch (_) {}
          }
        }(),
  ]);
  return found.values.toList();
});
