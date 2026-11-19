import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/config_store.dart';
import '../history/play_history.dart';
import '../config/app_config.dart';
import '../cache/account_scope.dart';
import '../emby/emby_client.dart';
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

  /// [resume]：继续播放（播放页起播前取服务器上最新的进度），见 PlayerPage.resume
  String playRoute({Duration position = Duration.zero, bool resume = false}) =>
      '/play/${item.serverId}/${item.id}?pos=${position.inMilliseconds}&source=${source.id}${resume ? '&resume=1' : ''}';
}

/// 这一集在各服务器上最近一次没看完的进度。各台的进度互不相通：在 A 服务器看到一半，
/// 详情页默认选中的是 B 服务器的版本（画质更好）时，也要接着 A 上的进度播
MediaItem? latestProgress(Iterable<SourceOption> options) {
  MediaItem? best;
  DateTime? bestAt;
  for (final o in options) {
    final it = o.item;
    if (it.played || it.position <= Duration.zero) continue;
    final at = PlayHistory.lastPlayed(it);
    if (best == null || (at != null && (bestAt == null || at.isAfter(bestAt)))) {
      best = it;
      bestAt = at;
    }
  }
  return best;
}

/// 播放 [o] 的路由。接着看时用 [all] 里最近的进度：就是这个版本自己的进度时让播放页再向服务器确认最新进度；
/// 进度来自别的服务器时直接从那个位置开始（这台服务器上的进度是 0，不能拿它覆盖）
String playRouteFor(SourceOption o, Iterable<SourceOption> all, {bool fromStart = false}) {
  if (fromStart) return o.playRoute();
  final latest = latestProgress(all);
  if (latest == null || (latest.serverId == o.serverId && latest.id == o.item.id)) {
    return o.playRoute(position: o.item.position, resume: true);
  }
  return o.playRoute(position: latest.position);
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

/// 详情页「逐台显示」：各服务器的版本陆续返回时的中间结果（已排序）。
/// 查找还没结束时页面先显示这里的版本，全部返回后改用完整结果。键见 [itemSourcesKey] 等。
final partialSourcesProvider = NotifierProvider.autoDispose.family<PartialSources, List<SourceOption>?, String>(
  PartialSources.new,
);

class PartialSources extends Notifier<List<SourceOption>?> {
  PartialSources(this.key);

  final String key;

  @override
  List<SourceOption>? build() => null;

  void publish(List<SourceOption> options) => state = options;
}

/// 逐台返回的中间结果 + 当前服务器自己的版本（中间结果里还没有的接在后面）
List<SourceOption> mergeSourceOptions(List<SourceOption>? partial, List<SourceOption>? home) {
  if (partial == null || partial.isEmpty) return home ?? const [];
  String id(SourceOption o) => '${o.serverId}/${o.item.id}/${o.source.id}';
  final seen = {for (final o in partial) id(o)};
  return [...partial, ...?home?.where((o) => seen.add(id(o)))];
}

String itemSourcesKey(SourcesKey k) => 'item:${k.serverId}/${k.itemId}';
String libraryEpisodeSourcesKey(LibraryEpisodeKey k) =>
    'lib:${k.series.home.serverId}/${k.series.home.itemId}/${k.season}/${k.episode}';
String tmdbSourcesKey(TmdbSearchKey k) => 'tmdb:${k.isTv}/${k.id}';
String tmdbEpisodeSourcesKey(TmdbEpisodeKey k) => 'tmdbep:${k.title.id}/${k.season}/${k.episode}';

/// 收集陆续返回的版本，每来一批就排好序发布到 [partialSourcesProvider]
class _Collector {
  _Collector(this.ref, this.key, this.rank);

  final Ref ref;
  final String key;
  final List<SourceOption> Function(List<SourceOption>) rank;
  final _all = <SourceOption>[];

  void add(List<SourceOption> options) {
    if (options.isEmpty || !ref.mounted) return;
    _all.addAll(options);
    ref.read(partialSourcesProvider(key).notifier).publish(rank(List.of(_all)));
  }
}

/// 取条目详情；这台服务器出错时用打开详情页时卡片上的信息（[ItemSeeds]），都没有才报错
Future<MediaItem> _itemOrSeed(EmbyClient client, String serverId, String itemId) async {
  try {
    return await client.item(itemId);
  } catch (_) {
    final seed = ItemSeeds.of(serverId, itemId);
    if (seed == null) rethrow;
    return seed;
  }
}

/// 某个电影 / 单集在所有服务器上的可播放版本（已排序）。
final sourceOptionsProvider = FutureProvider.family<List<SourceOption>, SourcesKey>((ref, key) async {
  ref.watch(mediaFeedScopeProvider);
  ref.watch(indexRevisionProvider);
  final home = ref.watch(serverClientProvider(key.serverId));
  if (home == null) return const [];
  final target = await _itemOrSeed(home, key.serverId, key.itemId);
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

  MediaItem titleItem = target;
  if (target.kind == MediaKind.episode && target.seriesId != null) {
    final seriesId = target.seriesId!;
    titleItem = await _itemOrSeed(home, target.serverId, seriesId).catchError(
      (Object _) => MediaItem(
        serverId: target.serverId,
        id: seriesId,
        kind: MediaKind.series,
        name: target.seriesName ?? target.name,
      ),
    );
  }
  final preferred = await PreferredServers.get(titleKeyOf(titleItem));
  final collector = _Collector(ref, itemSourcesKey(key), (o) => _rank(ref, o, preferred, home: target.serverId));

  // 2. 当前服务器的版本先查（不等其他服务器搜索），各服务器的版本谁先返回先显示
  final own = _optionsOf(ref, [target], onEach: collector.add);
  final copies = <MediaItem>[];
  if (target.kind == MediaKind.episode && target.seriesId != null) {
    final series = await copiesOf(titleItem);
    final found = await Future.wait(
      series.map((c) async {
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
    copies.addAll(found.whereType<MediaItem>());
  } else if (target.kind == MediaKind.movie) {
    copies.addAll(await copiesOf(target));
  }

  // 每台服务器只取一个条目（同一台服务器上重复入库的也保留，作为不同版本）
  final seen = <String>{'${target.serverId}/${target.id}'};
  final rest = copies.where((it) => seen.add('${it.serverId}/${it.id}')).toList();

  // 先把其他服务器的请求发出去再等：当前服务器慢时不拖住其他服务器
  final restOptions = _optionsOf(ref, rest, onEach: collector.add);
  final options = [...await own, ...await restOptions];
  return _rank(ref, options, preferred, home: target.serverId);
});

/// 并发获取每个条目的播放信息，展开成可播放版本；单台超时 / 失败不拖累整体
Future<List<SourceOption>> _optionsOf(
  Ref ref,
  List<MediaItem> targets, {
  void Function(List<SourceOption>)? onEach,
}) async {
  final config = ref.read(configProvider);
  final results = await Future.wait(
    targets.map((it) async {
      final client = ref.read(serverClientProvider(it.serverId));
      final server = config.server(it.serverId);
      if (client == null || server == null) return const <SourceOption>[];
      try {
        final info = await PlaybackPreloader.info(client, it.serverId, it.id).timeout(const Duration(seconds: 8));
        final latency = client.line.latencyMs;
        final options = [
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
        onEach?.call(options);
        return options;
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
  if (key.isTv) return const [];
  // 本地索引里已对上的副本先查版本（不等各服务器实时搜索），谁先返回先显示
  final indexed = ref
      .read(libraryCopiesProvider((isTv: key.isTv, id: key.id)))
      .where((c) => ref.read(configProvider).aggregateServerIds.contains(c.serverId))
      .toList();
  final preferred = indexed.isEmpty ? null : await PreferredServers.get(titleKeyOf(indexed.first));
  final collector = _Collector(ref, tmdbSourcesKey(key), (o) => _rank(ref, o, preferred));
  final early = _optionsOf(ref, indexed, onEach: collector.add);
  final copies = await ref.watch(tmdbLibrarySearchProvider(key).future);
  final seen = {for (final c in indexed) '${c.serverId}/${c.id}'};
  final rest = copies.where((c) => seen.add('${c.serverId}/${c.id}')).toList();
  final later = _optionsOf(ref, rest, onEach: collector.add);
  final options = [...await early, ...await later];
  if (options.isEmpty && copies.isEmpty) return const [];
  final remembered = preferred ?? (copies.isEmpty ? null : await PreferredServers.get(titleKeyOf(copies.first)));
  return _rank(ref, options, remembered);
});

/// 播放某个版本时记下偏好服务器
/// [series]：TMDB 剧集详情页传入，另按 TMDB ID 记一份（副本没有 TMDB ID 时读的也是这个键）
Future<void> rememberSource(MediaItem titleItem, String serverId, {TmdbSearchKey? series}) async {
  await PreferredServers.set(titleKeyOf(titleItem), serverId);
  if (series != null) await PreferredServers.set(seriesTitleKey(series), serverId);
}

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
  // 偏好服务器和各服务器的查询同时进行：读到之前返回的中间结果先按默认规则排
  String? preferred;
  final copies = ref.watch(tmdbLibrarySearchProvider(key.title).future);
  final remembered = _rememberedSeries(key.title, copies).then((p) => preferred = p);
  final collector = _Collector(ref, tmdbEpisodeSourcesKey(key), (o) => _rank(ref, o, preferred));
  final options = await _episodeOptions(ref, const [], copies, key.season, key.episode, collector.add);
  if (options.isEmpty) return const [];
  return _rank(ref, options, await remembered);
});

/// 这部剧上次用的服务器：先读 TMDB ID 的键（不用等搜索）；没有时读旧记录（副本没有 TMDB ID 时按 IMDb / 剧名记的键）
Future<String?> _rememberedSeries(TmdbSearchKey title, Future<List<MediaItem>> copies) async {
  final byTmdb = await PreferredServers.get(seriesTitleKey(title));
  if (byTmdb != null) return byTmdb;
  final found = await copies.catchError((Object _) => const <MediaItem>[]);
  return found.isEmpty ? null : PreferredServers.get(titleKeyOf(found.first));
}

/// 剧集的偏好服务器记录用的键（同 [titleKeyOf] 对有 TMDB ID 的剧）：不用等服务器返回剧集详情
String seriesTitleKey(TmdbSearchKey title) => 'tmdb:${MediaKind.series.name}:${title.id}';

/// 一集在各服务器上的版本：每台的集列表一回来就对季号 + 集号、查版本，不等最慢的那台。
/// [known] 是不用搜索就知道的副本（当前服务器），[copies] 是聚合搜索找到的副本；同一副本只查一次，单台失败跳过
Future<List<SourceOption>> _episodeOptions(
  Ref ref,
  List<SourcesKey> known,
  Future<List<MediaItem>> copies,
  int season,
  int episode,
  void Function(List<SourceOption>) onEach,
) async {
  final seen = <String>{};
  Future<List<SourceOption>> one(SourcesKey copy) async {
    if (!seen.add('${copy.serverId}/${copy.itemId}')) return const [];
    try {
      final episodes = await ref.watch(seriesEpisodesProvider(copy).future);
      final matches = episodes.where((e) => e.seasonNumber == season && e.episodeNumber == episode).toList();
      if (matches.isEmpty) return const [];
      return await _optionsOf(ref, matches, onEach: onEach);
    } catch (e) {
      debugPrint('episodes ${copy.serverId} failed: $e');
      return const [];
    }
  }

  final early = [for (final k in known) one(k)];
  final found = await copies.catchError((Object _) => const <MediaItem>[]);
  final later = [for (final c in found) one((serverId: c.serverId, itemId: c.id))];
  return [
    for (final list in await Future.wait([...early, ...later])) ...list,
  ];
}

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
/// 当前服务器的集列表先查，不等聚合搜索；当前服务器取不到剧集详情（如报 502）也不影响其他服务器
final libraryEpisodeSourcesProvider = FutureProvider.autoDispose.family<List<SourceOption>, LibraryEpisodeKey>((
  ref,
  key,
) async {
  ref.watch(
    configProvider.select((c) => (c.serversKey, c.parental.enabled, c.parental.maxAge, c.parental.blockUnrated)),
  );
  final home = key.series.home;
  String? preferred;
  final copies = ref.watch(tmdbLibrarySearchProvider(key.series.title).future);
  final remembered = _rememberedSeries(key.series.title, copies).then((p) => preferred = p);
  final collector = _Collector(
    ref,
    libraryEpisodeSourcesKey(key),
    (o) => _rank(ref, o, preferred, home: home.serverId),
  );
  final options = await _episodeOptions(ref, [home], copies, key.season, key.episode, collector.add);
  if (options.isEmpty) return const [];
  return _rank(ref, options, await remembered, home: home.serverId);
});

/// 自动换源用的版本标识：「服务器/版本 ID」
String failoverKey(SourceOption o) => '${o.serverId}/${o.source.id}';

/// 当前版本打不开时下一个要试的版本：按已有排序取第一个没试过的
SourceOption? nextFailoverOption(List<SourceOption> ranked, Set<String> tried) =>
    ranked.where((o) => !tried.contains(failoverKey(o))).firstOrNull;
