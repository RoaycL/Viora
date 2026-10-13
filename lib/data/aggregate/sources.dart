import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/config_store.dart';
import '../config/app_config.dart';
import '../cache/account_scope.dart';
import '../index/index_sync.dart';
import '../index/media_index.dart';
import '../media/media_models.dart';
import '../media/server_registry.dart';
import 'tmdb_link.dart';
import '../../player/preload.dart';

/// 一个可播放的版本：哪台服务器、哪个条目（电影 / 单集）、哪个 MediaSource（docs/04-aggregation.md §5）
@immutable
class SourceOption {
  const SourceOption({
    required this.item,
    required this.source,
    required this.serverName,
    this.latencyMs,
    this.account,
    this.view,
  });

  final MediaItem item;
  final MediaSourceInfo source;
  final String serverName;
  final int? latencyMs;
  final String? account;
  final String? view;

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

/// 同一账号刷新时保留可用资源；账号 / 家长限制变化时不能复用旧 AsyncValue 中的资源。
List<SourceOption> visibleSourceOptions(AppConfig config, Iterable<SourceOption> options) => [
  for (final option in options)
    if (config.server(option.serverId) case final server?
        when server.loggedIn &&
            option.account == accountScope(server) &&
            option.view == mediaViewScope(config) &&
            itemVisible(config, option.item))
      option,
];

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
  ref.watch(mediaFeedScopeProvider);
  ref.watch(indexRevisionProvider);
  final home = ref.watch(serverClientProvider(key.serverId));
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
            SourceOption(
              item: it,
              source: s,
              serverName: server.displayName,
              latencyMs: latency,
              account: accountScope(client.server),
              view: mediaViewScope(config),
            ),
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
  ref.watch(mediaFeedScopeProvider);
  final copies = await ref.watch(tmdbLibrarySearchProvider(key).future);
  if (key.isTv || copies.isEmpty) return const [];
  final options = await _optionsOf(ref, copies);
  final preferred = await PreferredServers.get(titleKeyOf(copies.first));
  return rankSources(options, preferredServerId: preferred);
});

/// 播放某个版本时记下偏好服务器
Future<void> rememberSource(MediaItem titleItem, String serverId) =>
    PreferredServers.set(titleKeyOf(titleItem), serverId);

/// TMDB 详情页（剧集）：聚合搜索找到的每个副本（各服务器上的这部剧）的全部单集。
/// 选中某一季某一集时，在这里按季号 + 集号对上各服务器的单集
final tmdbSeriesEpisodesProvider = FutureProvider.autoDispose.family<List<MediaItem>, TmdbSearchKey>((ref, key) async {
  ref.watch(mediaFeedScopeProvider);
  final copies = await ref.watch(tmdbLibrarySearchProvider(key).future);
  if (!key.isTv || copies.isEmpty) return const [];
  final lists = await Future.wait([
    for (final copy in copies) ref.watch(seriesEpisodesProvider((serverId: copy.serverId, itemId: copy.id)).future),
  ]);
  return [for (final list in lists) ...list];
});

typedef TmdbEpisodeKey = ({TmdbSearchKey title, int season, int episode});

/// TMDB 详情页（剧集）：选中的那一集在各服务器上的所有版本（已排序）
final tmdbEpisodeSourcesProvider = FutureProvider.autoDispose.family<List<SourceOption>, TmdbEpisodeKey>((
  ref,
  key,
) async {
  ref.watch(mediaFeedScopeProvider);
  final all = await ref.watch(tmdbSeriesEpisodesProvider(key.title).future);
  final matches = all.where((e) => e.seasonNumber == key.season && e.episodeNumber == key.episode).toList();
  if (matches.isEmpty) return const [];
  final options = await _optionsOf(ref, matches);
  final copies = await ref.watch(tmdbLibrarySearchProvider(key.title).future);
  final preferred = copies.isEmpty ? null : await PreferredServers.get(titleKeyOf(copies.first));
  return rankSources(options, preferredServerId: preferred);
});

/// 同一剧的全集只请求一次，TMDB 入口与媒体库入口共用。
final seriesEpisodesProvider = FutureProvider.autoDispose.family<List<MediaItem>, SourcesKey>((ref, key) async {
  final client = ref.watch(serverClientProvider(key.serverId));
  if (client == null) return const [];
  try {
    return await client.episodes(key.itemId).timeout(const Duration(seconds: 10));
  } catch (_) {
    return const [];
  }
});

typedef LibrarySeriesKey = ({SourcesKey home, TmdbSearchKey title});
typedef LibraryEpisodeKey = ({LibrarySeriesKey series, int season, int episode});

/// 当前服务器始终参与；其他服务器遵循聚合设置。即使当前来源关闭聚合，也能播放它自己的剧集。
final librarySeriesEpisodesProvider = FutureProvider.autoDispose.family<List<MediaItem>, LibrarySeriesKey>((
  ref,
  key,
) async {
  ref.watch(
    configProvider.select((c) => (c.serversKey, c.parental.enabled, c.parental.maxAge, c.parental.blockUnrated)),
  );
  final own = ref.watch(seriesEpisodesProvider(key.home).future);
  final others = ref.watch(tmdbSeriesEpisodesProvider(key.title).future);
  final lists = await Future.wait([own, others]);
  final unique = <String, MediaItem>{};
  for (final list in lists) {
    for (final item in list) {
      unique.putIfAbsent('${item.serverId}/${item.id}', () => item);
    }
  }
  return unique.values.toList();
});

/// 用季号和集号查实际资源，不根据播出日期过滤，也不拿下一集替代用户选择的缺集。
final libraryEpisodeSourcesProvider = FutureProvider.autoDispose.family<List<SourceOption>, LibraryEpisodeKey>((
  ref,
  key,
) async {
  final episodes = await ref.watch(librarySeriesEpisodesProvider(key.series).future);
  final matches = episodes.where((e) => e.seasonNumber == key.season && e.episodeNumber == key.episode).toList();
  if (matches.isEmpty) return const [];
  final options = await _optionsOf(ref, matches);
  final series = await ref.watch(itemProvider(key.series.home).future);
  final preferred = await PreferredServers.get(titleKeyOf(series));
  return rankSources(options, preferredServerId: preferred ?? key.series.home.serverId);
});
