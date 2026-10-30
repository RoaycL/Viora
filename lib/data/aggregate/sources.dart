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

/// 排序（默认选中第一个）：本剧上次用的服务器 → 按 [order]：
/// - 画质优先：分辨率 → 线路延迟 → 码率
/// - 速度优先：线路延迟 → 分辨率 → 码率
/// - 指定服务器优先：[pinnedServerId] → 分辨率 → 线路延迟 → 码率
/// 延迟相差 80ms 以内视为一样快。
List<SourceOption> rankSources(
  List<SourceOption> options, {
  String? preferredServerId,
  SourceOrder order = SourceOrder.quality,
  String? pinnedServerId,
}) {
  int first(SourceOption o, String? id) => id != null && o.serverId == id ? 1 : 0;
  int latency(SourceOption a, SourceOption b) {
    final la = a.latencyMs ?? 99999, lb = b.latencyMs ?? 99999;
    return (la - lb).abs() > 80 ? la - lb : 0;
  }

  int resolution(SourceOption a, SourceOption b) => b._resolutionRank - a._resolutionRank;
  final list = [...options];
  list.sort((a, b) {
    final preferred = first(b, preferredServerId) - first(a, preferredServerId);
    if (preferred != 0) return preferred;
    if (order == SourceOrder.server) {
      final pinned = first(b, pinnedServerId) - first(a, pinnedServerId);
      if (pinned != 0) return pinned;
    }
    final byOrder = order == SourceOrder.speed ? [latency(a, b), resolution(a, b)] : [resolution(a, b), latency(a, b)];
    for (final c in byOrder) {
      if (c != 0) return c;
    }
    return (b.source.bitrate ?? 0) - (a.source.bitrate ?? 0);
  });
  return list;
}

/// 按设置里的排序规则排序。[remembered] 是这部剧上次用的服务器（各规则都排最前）；
/// [home] 是正在浏览的服务器，只在画质优先（默认规则）下当作没有记录时的首选
List<SourceOption> _rank(Ref ref, List<SourceOption> options, String? remembered, {String? home}) {
  final playback = ref.read(configProvider).playback;
  return rankSources(
    options,
    preferredServerId: remembered ?? (playback.sourceOrder == SourceOrder.quality ? home : null),
    order: playback.sourceOrder,
    pinnedServerId: playback.pinnedServerId,
  );
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
  return _rank(ref, options, preferred, home: target.serverId);
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
  return _rank(ref, options, preferred);
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
  var failed = 0;
  final lists = await Future.wait([
    for (final copy in copies)
      ref.watch(seriesEpisodesProvider((serverId: copy.serverId, itemId: copy.id)).future).catchError((Object _) {
        failed++;
        return const <MediaItem>[];
      }),
  ]);
  // 全部副本都没拿到集列表：报错，页面不能据此把每一集标成「无资源」
  if (failed == copies.length) throw StateError('series episodes unavailable');
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
  return _rank(ref, options, preferred);
});

/// 同一剧的全集只请求一次，TMDB 入口与媒体库入口共用。
/// 超时 / 请求失败时是错误状态而不是空列表：空列表会被当成「这台服务器一集都没有」。
/// 不自动重试，下次进入详情页再请求。
final seriesEpisodesProvider = FutureProvider.autoDispose.family<List<MediaItem>, SourcesKey>((ref, key) async {
  final client = ref.watch(serverClientProvider(key.serverId));
  if (client == null) return const [];
  return client.episodes(key.itemId).timeout(const Duration(seconds: 10));
}, retry: (_, _) => null);

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
  // 单边失败时用另一边的集；当前服务器失败由页面看 seriesEpisodesProvider 的错误状态
  final own = ref.watch(seriesEpisodesProvider(key.home).future).catchError((Object _) => const <MediaItem>[]);
  final others = ref.watch(tmdbSeriesEpisodesProvider(key.title).future).catchError((Object _) => const <MediaItem>[]);
  final lists = await Future.wait([own, others]);
  final unique = <String, MediaItem>{};
  for (final list in lists) {
    for (final item in list) {
      unique.putIfAbsent('${item.serverId}/${item.id}', () => item);
    }
  }
  return unique.values.toList();
});

/// 只查当前服务器上这一集的版本：详情页先用它显示「播放」，不用等所有服务器搜完（其他服务器慢时要等十几秒）
final homeEpisodeSourcesProvider = FutureProvider.autoDispose.family<List<SourceOption>, LibraryEpisodeKey>((
  ref,
  key,
) async {
  final episodes = await ref.watch(seriesEpisodesProvider(key.series.home).future);
  final matches = episodes.where((e) => e.seasonNumber == key.season && e.episodeNumber == key.episode).toList();
  if (matches.isEmpty) return const [];
  return _rank(ref, await _optionsOf(ref, matches), null, home: key.series.home.serverId);
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
  return _rank(ref, options, preferred, home: key.series.home.serverId);
});

/// 自动换源用的版本标识：「服务器/版本 ID」
String failoverKey(SourceOption o) => '${o.serverId}/${o.source.id}';

/// 当前版本打不开时下一个要试的版本：按已有排序取第一个没试过的
SourceOption? nextFailoverOption(List<SourceOption> ranked, Set<String> tried) =>
    ranked.where((o) => !tried.contains(failoverKey(o))).firstOrNull;
