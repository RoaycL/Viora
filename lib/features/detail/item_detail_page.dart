import '../../ui/widgets/end_of_page.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/aggregate/sources.dart';
import '../../data/cache/account_scope.dart';
import '../../data/config/config_store.dart';
import '../../data/media/media_models.dart';
import '../../data/media/server_registry.dart';
import '../../data/tmdb/tmdb_client.dart';
import '../../domain/models/external_rating.dart';
import '../../player/preload.dart';
import '../../ui/focus/row_focus.dart';
import '../../ui/rows/cards.dart';
import '../../ui/rows/focus_row.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/server_image.dart';
import '../../ui/widgets/toast.dart';
import '../browse/media_cards.dart';
import '../metadata/external_ratings.dart';
import '../tmdb/tmdb_detail_page.dart';
import 'detail_layout.dart';
import 'source_widgets.dart';

typedef _Key = ({String serverId, String itemId});

final _seasonsProvider = FutureProvider.family<List<MediaItem>, _Key>((ref, k) async {
  final c = ref.watch(serverClientProvider(k.serverId));
  return c == null ? const [] : c.seasons(k.itemId);
});

final _episodesProvider = FutureProvider.family<List<MediaItem>, ({String serverId, String seriesId, String seasonId})>(
  (ref, k) async {
    final c = ref.watch(serverClientProvider(k.serverId));
    return c == null ? const [] : c.episodes(k.seriesId, seasonId: k.seasonId);
  },
);

final _nextUpProvider = FutureProvider.family<MediaItem?, _Key>((ref, k) async {
  final c = ref.watch(serverClientProvider(k.serverId));
  return c?.nextUp(k.itemId);
});

/// 媒体服务器条目的详情页（效果图：详情页 · 首屏 / 下滑）。
class ItemDetailPage extends ConsumerStatefulWidget {
  const ItemDetailPage({super.key, required this.serverId, required this.itemId});

  final String serverId;
  final String itemId;

  @override
  ConsumerState<ItemDetailPage> createState() => _ItemDetailPageState();
}

class _ItemDetailPageState extends ConsumerState<ItemDetailPage> {
  String? _seasonId;

  /// 选中的版本（[sourceKeyOf]）；没选时用排在第一的
  String? _sourceKey;
  bool? _favorite;
  bool? _played;
  int _accountGeneration = 0;

  /// 已预热的默认版本（同一版本只预热一次）
  String? _warmedKey;

  /// 播放资源出来后预热默认版本：按下播放时服务器 / 反代 / 网盘直链都已就绪
  void _warmDefault(SourceOption o) {
    final key = '${o.serverId}/${o.item.id}/${o.source.id}';
    if (_warmedKey == key) return;
    _warmedKey = key;
    final client = ref.read(serverClientProvider(o.serverId));
    if (client == null) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => PlaybackPreloader.warm(
        client,
        o.source,
        playSessionId: PlaybackPreloader.cached(
          o.serverId,
          o.item.id,
          scope: accountScope(client.server),
        )?.playSessionId,
        position: o.item.position,
      ),
    );
  }

  _Key get _key => (serverId: widget.serverId, itemId: widget.itemId);

  @override
  Widget build(BuildContext context) {
    ref.listen(
      configProvider.select((c) {
        final server = c.server(widget.serverId);
        return server == null || !server.loggedIn ? null : accountScope(server);
      }),
      (_, _) {
        _accountGeneration++;
        _favorite = null;
        _played = null;
        _seasonId = null;
        _sourceKey = null;
        _warmedKey = null;
      },
    );
    final async = ref.watch(itemProvider(_key));
    return Material(
      color: VColors.background,
      child: switch (async) {
        AsyncData(value: final item) => _content(item),
        AsyncError(:final error) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(error.toString(), style: VText.label.copyWith(color: VColors.bad)),
              const SizedBox(height: 24),
              PillButton(
                autofocus: true,
                icon: Icons.refresh_rounded,
                label: '重试',
                onPressed: () => ref.invalidate(itemProvider(_key)),
              ),
            ],
          ),
        ),
        _ => const Center(child: Text('加载中…', style: VText.label)),
      },
    );
  }

  Widget _content(MediaItem item) {
    final isSeries = item.kind == MediaKind.series;
    final seasons = isSeries ? ref.watch(_seasonsProvider(_key)).value ?? const <MediaItem>[] : const <MediaItem>[];
    final seasonId = _seasonId ?? seasons.firstOrNull?.id;
    final episodes = isSeries && seasonId != null
        ? ref.watch(_episodesProvider((serverId: widget.serverId, seriesId: item.id, seasonId: seasonId))).value ??
              const <MediaItem>[]
        : const <MediaItem>[];
    final nextUp = isSeries ? ref.watch(_nextUpProvider(_key)).value : null;

    final zh = localizedMeta(ref, item);
    // TMDB 补全：演职员与相似推荐
    final tmdbId = int.tryParse(item.tmdbId ?? '');
    final tmdb = tmdbId != null && (isSeries || item.kind == MediaKind.movie)
        ? ref.watch(tmdbTitleProvider((isTv: isSeries, id: tmdbId))).value
        : null;
    final parent = item.kind == MediaKind.episode && item.seriesId != null
        ? ref.watch(itemProvider((serverId: item.serverId, itemId: item.seriesId!))).value
        : null;
    final ratingsQuery = switch (item.kind) {
      MediaKind.movie || MediaKind.series => RatingQuery(
        kind: isSeries ? RatingMediaKind.series : RatingMediaKind.movie,
        imdbId: RatingQuery.validImdb(item.imdbId) ? item.imdbId : tmdb?.imdbId,
        tmdbId: tmdbId,
      ),
      MediaKind.episode => RatingQuery(
        kind: RatingMediaKind.episode,
        imdbId: item.imdbId,
        seriesImdbId: parent?.imdbId,
        seriesTmdbId: int.tryParse(parent?.tmdbId ?? ''),
        season: item.seasonNumber,
        episode: item.episodeNumber,
      ),
      _ => null,
    };
    final favorite = _favorite ?? item.favorite;
    final played = _played ?? item.played;
    final playTarget = isSeries ? (nextUp ?? episodes.firstOrNull) : item;
    final resumeAt = playTarget?.position ?? Duration.zero;
    // 所有服务器上的可播放版本（已按偏好服务器 / 分辨率 / 延迟 / 码率排序）
    final optionsAsync = playTarget == null
        ? null
        : ref.watch(sourceOptionsProvider((serverId: playTarget.serverId, itemId: playTarget.id)));
    final options = visibleSourceOptions(ref.read(configProvider), optionsAsync?.value ?? const <SourceOption>[]);
    final selected = options.where((o) => sourceKeyOf(o) == _sourceKey).firstOrNull ?? options.firstOrNull;
    if (selected != null) _warmDefault(selected);
    void play(SourceOption? o, {bool fromStart = false}) {
      final target = playTarget;
      if (target == null) return;
      if (o == null) {
        playMediaItem(context, target, fromStart: fromStart);
        return;
      }
      rememberSource(item, o.serverId);
      context.push(o.playRoute(position: fromStart ? Duration.zero : o.item.position));
    }

    final playLabel = switch (playTarget) {
      null => '暂无可播放内容',
      final t when resumeAt > Duration.zero =>
        '继续${t.episodeLabel == null ? '' : ' ${t.episodeLabel}'} · ${formatClock(resumeAt)}',
      final t when t.kind == MediaKind.episode => '播放 ${t.episodeLabel ?? t.name}',
      _ => '播放',
    };

    final meta = [
      if (item.year != null) '${item.year}',
      if (zh.genres.isNotEmpty) zh.genres.take(3).join(' / '),
      if (item.runtime != null && !isSeries) formatDuration(item.runtime!),
      if (isSeries && seasons.isNotEmpty) '${seasons.length} 季',
      ?item.officialRating,
    ].join('  •  ');

    return DetailLayout(
      seed: item.id,
      backdrop: ServerImage(
        serverId: widget.serverId,
        image: item.backdrop ?? item.primary,
        width: 1920,
        fallbackSeed: item.id,
        alignment: Alignment.topRight,
        transparentFallback: true,
      ),
      info: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Title(serverId: widget.serverId, item: item, title: zh.title),
          if (item.kind == MediaKind.episode && item.seriesName != null) ...[
            const SizedBox(height: 12),
            Text(
              '${item.seriesName}  ${item.episodeLabel ?? ''}',
              style: VText.label.copyWith(color: VColors.textSecondary),
            ),
          ],
          const SizedBox(height: 22),
          Text(meta, style: const TextStyle(fontSize: 22, color: Color(0xD1FFFFFF))),
          ExternalRatings(
            query: ratingsQuery,
            serverRating: item.rating,
            criticRating: item.criticRating,
            serverCertification: item.officialRating,
          ),
          if (zh.overview?.isNotEmpty == true) ...[
            const SizedBox(height: 18),
            Text(
              zh.overview!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: VText.body.copyWith(color: const Color(0xCCFFFFFF), height: 1.65),
            ),
          ],
        ],
      ),
      buttons: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RowAutoFocus(),
          FocusButtonRow(
            rowIndex: 0,
            scrollToTop: true,
            children: [
              (node) => PillButton(
                focusNode: node,
                large: true,
                icon: Icons.play_arrow_rounded,
                label: playLabel,
                onPressed: playTarget == null ? null : () => play(selected),
              ),
              if (resumeAt > Duration.zero)
                (node) => PillButton(
                  focusNode: node,
                  icon: Icons.replay_rounded,
                  label: '从头播放',
                  onPressed: () => play(selected, fromStart: true),
                ),
              (node) => CircleIconButton(
                focusNode: node,
                icon: favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                tooltip: favorite ? '取消收藏' : '收藏',
                onPressed: () => _toggleFavorite(item, !favorite),
              ),
              (node) => CircleIconButton(
                focusNode: node,
                icon: played ? Icons.check_circle_rounded : Icons.check_rounded,
                tooltip: played ? '标记未看' : '标记已看',
                onPressed: () => _togglePlayed(item, !played),
              ),
            ],
          ),
        ],
      ),
      below: [
        const SizedBox(height: 48),
        if (isSeries && seasons.length > 1)
          Padding(
            padding: const EdgeInsets.only(left: VSpace.safeH),
            child: FocusButtonRow(
              rowIndex: 1,
              spacing: 12,
              children: [
                for (final s in seasons)
                  (node) => SelectChip(
                    node: node,
                    label: s.name,
                    selected: s.id == seasonId,
                    onTap: () => setState(() => _seasonId = s.id),
                  ),
              ],
            ),
          ),
        if (episodes.isNotEmpty)
          FocusRow(
            rowIndex: 2,
            leading: VSpace.safeH,
            title: seasons.length <= 1 ? '剧集' : null,
            itemCount: episodes.length,
            itemExtent: LandscapeCard.width,
            height: LandscapeCard.height,
            itemBuilder: (context, i, node) =>
                mediaLandscapeCard(context, episodes[i], node, onMenu: () => openMediaItem(context, episodes[i])),
          ),
        if (optionsAsync != null) ...[
          const SizedBox(height: 24),
          SourcesSection(
            options: options,
            loading: optionsAsync.isLoading,
            selected: selected,
            onSelect: (o) => setState(() => _sourceKey = sourceKeyOf(o)),
            onPlay: play,
            firstRow: 3,
            caption: playTarget?.episodeLabel,
          ),
        ],
        if (tmdb != null) ...[const SizedBox(height: 24), ...tmdbExtraRows(tmdb, firstRow: 3 + SourcesSection.rows)],
        const EndOfPage(leading: VSpace.safeH),
      ],
    );
  }

  Future<void> _toggleFavorite(MediaItem item, bool value) async {
    final client = ref.read(serverClientProvider(widget.serverId));
    if (client == null) return;
    final generation = _accountGeneration;
    final refresh = ref.read(mediaFeedRefreshProvider.notifier);
    setState(() => _favorite = value);
    try {
      await client.setFavorite(item.id, value);
      refresh.refresh(MediaFeedKind.favorites);
      if (!mounted || generation != _accountGeneration) return;
      showToast(value ? '已收藏' : '已取消收藏');
    } catch (e) {
      if (!mounted || generation != _accountGeneration) return;
      setState(() => _favorite = !value);
      showToast('操作失败：$e');
    }
  }

  Future<void> _togglePlayed(MediaItem item, bool value) async {
    final client = ref.read(serverClientProvider(widget.serverId));
    if (client == null) return;
    final generation = _accountGeneration;
    final refresh = ref.read(mediaFeedRefreshProvider.notifier);
    setState(() => _played = value);
    try {
      await client.setPlayed(item.id, value);
      refresh.refresh(MediaFeedKind.recentlyPlayed);
      if (!mounted || generation != _accountGeneration) return;
      showToast(value ? '已标记为已看' : '已标记为未看');
    } catch (e) {
      if (!mounted || generation != _accountGeneration) return;
      setState(() => _played = !value);
      showToast('操作失败：$e');
    }
  }
}

/// 有 Logo 显示 Logo 图，否则显示大字标题。
class _Title extends StatelessWidget {
  const _Title({required this.serverId, required this.item, required this.title});

  final String serverId;
  final MediaItem item;
  final String title;

  @override
  Widget build(BuildContext context) {
    final text = Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: VText.titleFor(title));
    // 标题已换成中文时不用（通常是英文的）Logo 图
    if (item.logo == null || item.kind == MediaKind.episode || title != item.name) return text;
    return SizedBox(
      height: 160,
      width: 640,
      child: ServerImage(
        serverId: serverId,
        image: item.logo,
        width: 640,
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        fallbackSeed: item.id,
        transparentFallback: true,
      ),
    );
  }
}
