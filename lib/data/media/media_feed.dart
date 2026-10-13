import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cache/account_scope.dart';
import '../cache/snapshot_cache.dart';
import '../config/app_config.dart';
import '../emby/emby_client.dart';
import 'media_models.dart';

enum MediaFeedKind { resume, favorites, recentlyPlayed }

class MediaFeedResult {
  const MediaFeedResult(this.snapshot);
  final SnapshotBatch<List<MediaItem>> snapshot;
  List<MediaItem> get items => [for (final s in snapshot.sources) ...?s.value];
  int get failures => snapshot.failures;
  bool get refreshing => snapshot.refreshing;
  String get note => failures > 0 ? '$failures 台服务器暂未刷新' : (refreshing ? '更新中…' : '');
}

Future<MediaFeedResult> loadMediaFeed(
  Ref ref,
  MediaFeedKind kind,
  String scope,
  AppConfig config,
  List<EmbyClient> clients,
) async {
  final view = mediaViewScope(config);
  final result = await sourceSnapshotsFirst<List<MediaItem>>(
    ref,
    'media-v2-${kind.name}-$scope',
    operation: kind.name,
    sources: [
      for (final client in clients)
        SnapshotSource(
          key: 'media-v2-${kind.name}-${accountScope(client.server)}-$view',
          id: accountScope(client.server).substring(0, 10),
          encode: MediaItem.encodeList,
          decode: (json) {
            final items = MediaItem.decodeList(json);
            if (items.any((it) => it.serverId != client.server.id)) throw const FormatException();
            return items;
          },
          fetch: () => fetchMediaFeed(client, kind),
        ),
    ],
  );
  return MediaFeedResult(result);
}

/// 继续观看和最近看过是固定窗口；收藏必须分页完整，不能把截断数据当作删除。
Future<SnapshotFetch<List<MediaItem>>> fetchMediaFeed(EmbyClient client, MediaFeedKind kind) async {
  switch (kind) {
    case MediaFeedKind.resume:
      return SnapshotFetch(await client.resume(limit: 12).timeout(const Duration(seconds: 10)));
    case MediaFeedKind.recentlyPlayed:
      final page = await client
          .items(types: 'Movie,Episode', filters: 'IsPlayed', limit: 60, sortBy: 'DatePlayed', sortOrder: 'Descending')
          .timeout(const Duration(seconds: 10));
      return SnapshotFetch(page.items, complete: !(page.totalKnown && page.total > 0 && page.receivedCount == 0));
    case MediaFeedKind.favorites:
      return fetchFavoritePages(client);
  }
}

Future<SnapshotFetch<List<MediaItem>>> fetchFavoritePages(EmbyClient client) async {
  const pageSize = 200;
  const deadline = Duration(seconds: 10);
  final watch = Stopwatch()..start();
  final items = <String, MediaItem>{};
  var start = 0;
  int? expectedTotal;
  while (true) {
    final remaining = deadline - watch.elapsed;
    if (remaining <= Duration.zero) throw TimeoutException('favorite pages');
    final page = await client
        .items(filters: 'IsFavorite', start: start, limit: pageSize, sortBy: 'SortName', sortOrder: 'Ascending')
        .timeout(remaining);
    if (page.totalKnown) {
      if (expectedTotal != null && expectedTotal != page.total) {
        return SnapshotFetch(items.values.toList(), complete: false);
      }
      expectedTotal = page.total;
    }
    // 分页中条目移动 / 服务器忽略 StartIndex：旧数据不能被这个不完整集合替换。
    for (final item in page.items) {
      if (items.containsKey(item.id)) return SnapshotFetch(items.values.toList(), complete: false);
      items[item.id] = item;
    }
    if (page.receivedCount == 0) {
      return SnapshotFetch(items.values.toList(), complete: expectedTotal == null || start == expectedTotal);
    }
    start += page.receivedCount;
    if (expectedTotal != null && start >= expectedTotal) {
      return SnapshotFetch(items.values.toList(), complete: start == expectedTotal);
    }
    // 没有总数时继续读到空页；服务器可能把每页限制在比请求值更小的数量。
  }
}
