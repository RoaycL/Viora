import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/config_store.dart';
import '../index/index_sync.dart';
import '../index/media_index.dart';
import '../media/media_models.dart';
import '../media/server_registry.dart';
import 'tmdb_link.dart';
import '../../player/preload.dart';

/// 一个可播放的版本：哪台服务器、哪个条目（电影 / 单集）、哪个 MediaSource（docs/04-aggregation.md §5）
@immutable
class SourceOption {
  const SourceOption({required this.item, required this.source, required this.serverName, this.latencyMs});

  final MediaItem item;
  final MediaSourceInfo source;
  final String serverName;
  final int? latencyMs;

  String get serverId => item.serverId;

  /// 4K / 1080P / 其他
  String get group => switch (source.resolutionLabel) {
    '4K' => '4K',
    '1080P' => '1080P',
    _ => '其他',
  };

  int get _resolutionRank => switch (source.resolutionLabel) {
    '4K' => 3,
    '1080P' => 2,
    '720P' => 1,
    _ => 0,
  };

  String playRoute({Duration position = Duration.zero}) =>
      '/play/${item.serverId}/${item.id}?pos=${position.inMilliseconds}&source=${source.id}';
}

/// 排序（默认选中第一个）：本剧上次用的服务器 → 分辨率 → 线路延迟 → 码率
List<SourceOption> rankSources(List<SourceOption> options, {String? preferredServerId}) {
  final list = [...options];
  list.sort((a, b) {
    final pa = a.serverId == preferredServerId ? 1 : 0, pb = b.serverId == preferredServerId ? 1 : 0;
    if (pa != pb) return pb - pa;
    if (a._resolutionRank != b._resolutionRank) return b._resolutionRank - a._resolutionRank;
    final la = a.latencyMs ?? 99999, lb = b.latencyMs ?? 99999;
    if ((la - lb).abs() > 80) return la - lb;
    return (b.source.bitrate ?? 0) - (a.source.bitrate ?? 0);
  });
  return list;
}

/// 记住每部作品上次播放用的服务器（同一部剧连续观看时不跳服务器）
class PreferredServers {
  static const _prefix = 'viora.prefServer.';

  static Future<String?> get(String titleKey) async {
    try {
      return (await SharedPreferences.getInstance()).getString('$_prefix$titleKey');
    } catch (_) {
      return null;
    }
  }

  static Future<void> set(String titleKey, String serverId) async {
    try {
      await (await SharedPreferences.getInstance()).setString('$_prefix$titleKey', serverId);
    } catch (_) {}
  }
}

typedef SourcesKey = ({String serverId, String itemId});

/// 某个电影 / 单集在所有服务器上的可播放版本（已排序）。
final sourceOptionsProvider = FutureProvider.family<List<SourceOption>, SourcesKey>((ref, key) async {
  ref.watch(indexRevisionProvider);
  final home = ref.read(serverClientProvider(key.serverId));
  if (home == null) return const [];
  final target = await home.item(key.itemId);
  final index = await ref.read(mediaIndexProvider.future);

  // 1. 找到每台服务器上对应的条目：本地索引 + 到参与聚合搜索的服务器上实时搜索（索引里没对上的也能找到）
  watchAggregateServers(ref);
  final others = ref.read(configProvider).aggregateServerIds..remove(target.serverId);
  Future<List<MediaItem>> copiesOf(MediaItem title) async {
    final probe = TitleProbe(
      kind: title.kind,
      titles: [title.name, title.originalTitle],
      year: title.year,
      tmdbId: title.tmdbId,
      imdbId: title.imdbId,
      tvdbId: title.tvdbId,
    );
    final found = <String, MediaItem>{
      for (final c in index?.matches(title) ?? const <MediaItem>[])
        if (others.contains(c.serverId)) '${c.serverId}/${c.id}': c,
    };
    for (final it in await searchServersFor(ref, probe, others)) {
      found.putIfAbsent('${it.serverId}/${it.id}', () => it);
    }
    return found.values.toList();
  }

  final perServer = <MediaItem>[target];
  MediaItem titleItem = target;
  if (target.kind == MediaKind.episode && target.seriesId != null) {
    final series = await home.item(target.seriesId!);
    titleItem = series;
    final copies = await copiesOf(series);
    final found = await Future.wait(
      copies.map((c) async {
        final client = ref.read(serverClientProvider(c.serverId));
        if (client == null) return null;
        try {
          final eps = await client.episodes(c.id).timeout(const Duration(seconds: 8));
          return eps
              .where((e) => e.seasonNumber == target.seasonNumber && e.episodeNumber == target.episodeNumber)
              .firstOrNull;
        } catch (_) {
          return null;
        }
      }),
    );
    perServer.addAll(found.whereType<MediaItem>());
  } else if (target.kind == MediaKind.movie) {
    perServer.addAll(await copiesOf(target));
  }

  // 每台服务器只取一个条目（同一台服务器上重复入库的也保留，作为不同版本）
  final seen = <String>{};
  final targets = perServer.where((it) => seen.add('${it.serverId}/${it.id}')).toList();

  final options = await _optionsOf(ref, targets);
  final preferred = await PreferredServers.get(titleKeyOf(titleItem));
  return rankSources(options, preferredServerId: preferred ?? target.serverId);
});

/// 并发获取每个条目的播放信息，展开成可播放版本；单台超时 / 失败不拖累整体
Future<List<SourceOption>> _optionsOf(Ref ref, List<MediaItem> targets) async {
  final config = ref.read(configProvider);
  final results = await Future.wait(
    targets.map((it) async {
      final client = ref.read(serverClientProvider(it.serverId));
      final server = config.server(it.serverId);
      if (client == null || server == null) return const <SourceOption>[];
      try {
        final info = await PlaybackPreloader.info(client, it.serverId, it.id).timeout(const Duration(seconds: 8));
        final latency = client.line.latencyMs;
        return [
          for (final s in info.sources)
            SourceOption(item: it, source: s, serverName: server.displayName, latencyMs: latency),
        ];
      } catch (e) {
        debugPrint('playbackInfo ${server.name} failed: $e');
        return const <SourceOption>[];
      }
    }),
  );
  return [for (final r in results) ...r];
}

/// TMDB 详情页（电影）：聚合搜索找到的各服务器副本 → 每个副本的所有版本（已排序）。剧集返回空，到媒体库详情页选集。
final tmdbSourceOptionsProvider = FutureProvider.autoDispose.family<List<SourceOption>, TmdbSearchKey>((
  ref,
  key,
) async {
  final copies = await ref.watch(tmdbLibrarySearchProvider(key).future);
  if (key.isTv || copies.isEmpty) return const [];
  final options = await _optionsOf(ref, copies);
  final preferred = await PreferredServers.get(titleKeyOf(copies.first));
  return rankSources(options, preferredServerId: preferred);
});

/// 播放某个版本时记下偏好服务器
Future<void> rememberSource(MediaItem titleItem, String serverId) =>
    PreferredServers.set(titleKeyOf(titleItem), serverId);
