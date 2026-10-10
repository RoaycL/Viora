import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/config_store.dart';
import '../index/index_sync.dart';
import '../index/media_index.dart';
import '../media/media_models.dart';
import '../tmdb/tmdb_models.dart';

typedef TmdbLinkKey = ({bool isTv, int id});

/// TMDB 条目在媒体库里的副本（按聚合索引的 TMDB ID 匹配；索引未就绪时为空）
final libraryCopiesProvider = Provider.family<List<MediaItem>, TmdbLinkKey>((ref, key) {
  ref.watch(indexRevisionProvider);
  final index = ref.watch(mediaIndexProvider).value;
  if (index == null) return const [];
  final servers = ref.watch(configProvider.select((c) => {for (final s in c.servers) s.id}));
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
  final servers = ref.watch(configProvider.select((c) => {for (final s in c.servers) s.id}));
  try {
    return groupTitles(index.latest(limit: 60).where((c) => servers.contains(c.serverId))).take(24).toList();
  } catch (_) {
    return const [];
  }
});
