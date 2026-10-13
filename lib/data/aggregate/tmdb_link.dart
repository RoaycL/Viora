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
  ref.watch(
    configProvider.select((c) => (c.serversKey, c.parental.enabled, c.parental.maxAge, c.parental.blockUnrated)),
  );
  final config = ref.read(configProvider);
  final servers = {for (final s in config.servers) s.id};
  try {
    return index
        .byTmdb(key.isTv ? MediaKind.series : MediaKind.movie, '${key.id}')
        .where((c) => servers.contains(c.serverId) && itemVisible(config, c))
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
  ref.watch(
    configProvider.select((c) => (c.serversKey, c.parental.enabled, c.parental.maxAge, c.parental.blockUnrated)),
  );
  final config = ref.read(configProvider);
  final servers = {for (final s in config.servers) s.id};
  try {
    return balancedLatest([
      for (final c in index.latestPerServer(perServer: 30))
        if (servers.contains(c.serverId) && itemVisible(config, c)) c,
    ]);
  } catch (_) {
    return const [];
  }
});

/// TMDB 详情页要找的作品
typedef TmdbSearchKey = ({bool isTv, int id, String title, String? originalTitle, int? year});

TmdbSearchKey searchKeyOf(TmdbTitle t) =>
    (isTv: t.isTv, id: t.id, title: t.title, originalTitle: t.originalTitle, year: t.year);

/// 要在各服务器上找的作品：有 ID 时按 ID 比对（双方都有才比），否则按中文名 / 原名 + 年份 ±1
class TitleProbe {
  TitleProbe({
    required this.kind,
    required Iterable<String?> titles,
    this.year,
    String? tmdbId,
    String? imdbId,
    String? tvdbId,
  }) : terms = {
         for (final t in titles)
           if (t != null && t.trim().isNotEmpty) t.trim(),
       }.toList(),
       names = {
         for (final t in titles)
           if (t != null && normalizeTitle(t).isNotEmpty) normalizeTitle(t),
       },
       ids = [_blank(tmdbId), _blank(imdbId), _blank(tvdbId)];

  final MediaKind kind;
  final int? year;

  /// 到服务器上搜索用的关键词
  final List<String> terms;
  final Set<String> names;
  final List<String?> ids;

  static String? _blank(String? v) => v == null || v.trim().isEmpty ? null : v.trim();

  bool matches(MediaItem it) {
    if (it.kind != kind) return false;
    final theirs = [_blank(it.tmdbId), _blank(it.imdbId), _blank(it.tvdbId)];
    for (var i = 0; i < ids.length; i++) {
      if (ids[i] != null && theirs[i] != null) return ids[i] == theirs[i];
    }
    if (!{it.name, ?it.originalTitle}.map(normalizeTitle).any(names.contains)) return false;
    return year == null || it.year == null || (year! - it.year!).abs() <= 1;
  }
}

/// 到 [serverIds] 每台服务器上按关键词实时搜索（每台每个关键词 1 次请求、8 秒超时），返回匹配 [probe] 的条目
Future<List<MediaItem>> searchServersFor(Ref ref, TitleProbe probe, Iterable<String> serverIds) async {
  final found = <String, MediaItem>{};
  final config = ref.read(configProvider);
  await Future.wait([
    for (final id in serverIds)
      if (config.server(id)?.loggedIn ?? false)
        () async {
          final client = ref.read(serverClientProvider(id));
          if (client == null) return;
          for (final term in probe.terms) {
            try {
              final page = await client
                  .items(searchTerm: term, types: probe.kind == MediaKind.series ? 'Series' : 'Movie', limit: 20)
                  .timeout(const Duration(seconds: 8));
              for (final it in page.items) {
                if (probe.matches(it) && itemVisible(config, it)) found['${it.serverId}/${it.id}'] = it;
              }
            } catch (_) {}
          }
        }(),
  ]);
  return found.values.toList();
}

/// 参与聚合搜索的服务器变化时刷新依赖它的 provider
String watchAggregateServers(Ref ref) =>
    ref.watch(configProvider.select((c) => (c.aggregateServerIds.toList()..sort()).join(',')));

/// 进入 TMDB 详情页时才做的聚合搜索：本地索引 + 到每台参与聚合搜索的服务器按中文名 / 原名实时搜索，
/// 按 TMDB ID 匹配（服务器条目没有 TMDB ID 时按标题 + 年份 ±1）。首页、推荐行不触发（docs/04-aggregation.md §7）。
final tmdbLibrarySearchProvider = FutureProvider.autoDispose.family<List<MediaItem>, TmdbSearchKey>((ref, key) async {
  ref.watch(mediaFeedScopeProvider);
  watchAggregateServers(ref);
  final servers = ref.read(configProvider).aggregateServerIds;
  final found = <String, MediaItem>{
    for (final c in ref.read(libraryCopiesProvider((isTv: key.isTv, id: key.id))))
      if (servers.contains(c.serverId)) '${c.serverId}/${c.id}': c,
  };
  final probe = TitleProbe(
    kind: key.isTv ? MediaKind.series : MediaKind.movie,
    titles: [key.title, key.originalTitle],
    year: key.year,
    tmdbId: '${key.id}',
  );
  for (final it in await searchServersFor(ref, probe, servers)) {
    found['${it.serverId}/${it.id}'] = it;
  }
  return found.values.toList();
});
