import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/aggregate/sources.dart';
import '../../data/media/media_models.dart';
import '../../data/media/server_registry.dart';
import '../../data/tmdb/tmdb_client.dart';
import '../../player/preload.dart';
import '../../ui/focus/focusable.dart';
import '../../ui/focus/row_focus.dart';
import '../../ui/rows/cards.dart';
import '../../ui/rows/focus_row.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/server_image.dart';
import '../../ui/widgets/toast.dart';
import '../browse/media_cards.dart';
import '../tmdb/tmdb_detail_page.dart';

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
  String? _group;
  bool? _favorite;
  bool? _played;

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
        playSessionId: PlaybackPreloader.cached(o.serverId, o.item.id)?.playSessionId,
        position: o.item.position,
      ),
    );
  }

  _Key get _key => (serverId: widget.serverId, itemId: widget.itemId);

  @override
  Widget build(BuildContext context) {
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
    final favorite = _favorite ?? item.favorite;
    final played = _played ?? item.played;
    final playTarget = isSeries ? (nextUp ?? episodes.firstOrNull) : item;
    final resumeAt = playTarget?.position ?? Duration.zero;
    // 所有服务器上的可播放版本（已按偏好服务器 / 分辨率 / 延迟 / 码率排序）
    final optionsAsync = playTarget == null
        ? null
        : ref.watch(sourceOptionsProvider((serverId: playTarget.serverId, itemId: playTarget.id)));
    final options = optionsAsync?.value ?? const <SourceOption>[];
    if (options.isNotEmpty) _warmDefault(options.first);
    final groups = [
      for (final g in const ['4K', '1080P', '其他'])
        if (options.any((o) => o.group == g)) g,
    ];
    final group = groups.contains(_group) ? _group! : groups.firstOrNull;
    final shown = options.where((o) => o.group == group).toList();
    final serverCount = options.map((o) => o.serverId).toSet().length;
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

    return Stack(
      children: [
        Positioned.fill(
          child: ServerImage(
            serverId: widget.serverId,
            image: item.backdrop ?? item.primary,
            width: 1920,
            fallbackSeed: item.id,
            alignment: Alignment.topRight,
          ),
        ),
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                stops: [0, 0.32, 0.62, 1],
                colors: [Color(0xCC07080B), Color(0xA607080B), Color(0x3307080B), Color(0x0007080B)],
              ),
            ),
          ),
        ),
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.45, 0.85],
                colors: [Color(0x0007080B), VColors.background],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: RowFocusScope(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 130, bottom: 360),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: VSpace.safeH),
                    child: SizedBox(
                      width: 1000,
                      child: Column(
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
                          if (item.rating != null && item.rating! > 0) ...[
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                const Icon(Icons.star_rounded, color: VColors.rating, size: 26),
                                const SizedBox(width: 6),
                                Text(
                                  item.rating!.toStringAsFixed(1),
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w600,
                                    color: VColors.rating,
                                  ),
                                ),
                              ],
                            ),
                          ],
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
                    ),
                  ),
                  const SizedBox(height: 36),
                  const RowAutoFocus(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: VSpace.safeH),
                    child: FocusButtonRow(
                      rowIndex: 0,
                      children: [
                        (node) => PillButton(
                          focusNode: node,
                          large: true,
                          icon: Icons.play_arrow_rounded,
                          label: playLabel,
                          onPressed: playTarget == null ? null : () => play(options.firstOrNull),
                        ),
                        if (resumeAt > Duration.zero)
                          (node) => PillButton(
                            focusNode: node,
                            icon: Icons.replay_rounded,
                            label: '从头播放',
                            onPressed: () => play(options.firstOrNull, fromStart: true),
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
                  ),
                  const SizedBox(height: 48),
                  if (isSeries && seasons.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(left: VSpace.safeH),
                      child: FocusButtonRow(
                        rowIndex: 1,
                        spacing: 12,
                        children: [
                          for (final s in seasons)
                            (node) => _SeasonChip(
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
                      itemBuilder: (context, i, node) => mediaLandscapeCard(
                        context,
                        episodes[i],
                        node,
                        onMenu: () => openMediaItem(context, episodes[i]),
                      ),
                    ),
                  if (optionsAsync != null && optionsAsync.isLoading && options.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(VSpace.safeH, 24, VSpace.safeH, 0),
                      child: Text('正在查找各服务器上的资源…', style: VText.label.copyWith(color: VColors.textTertiary)),
                    ),
                  if (options.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(VSpace.safeH, 24, VSpace.safeH, 16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text('播放资源', style: VText.rowTitle.copyWith(color: const Color(0xEBFFFFFF))),
                          const SizedBox(width: 16),
                          Text(
                            '${options.length} 个版本 · $serverCount 台服务器'
                            '${playTarget?.episodeLabel == null ? '' : ' · ${playTarget!.episodeLabel}'}',
                            style: VText.caption.copyWith(color: VColors.textTertiary),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: VSpace.safeH),
                      child: FocusButtonRow(
                        rowIndex: 3,
                        spacing: 12,
                        children: [
                          for (final g in groups)
                            (node) => _SeasonChip(
                              node: node,
                              label: '$g · ${options.where((o) => o.group == g).length}',
                              selected: g == group,
                              onTap: () => setState(() => _group = g),
                            ),
                        ],
                      ),
                    ),
                    FocusRow(
                      rowIndex: 4,
                      leading: VSpace.safeH,
                      itemCount: shown.length,
                      itemExtent: 420,
                      height: 220,
                      itemBuilder: (context, i, node) => _SourceCard(
                        node: node,
                        option: shown[i],
                        isDefault: identical(shown[i], options.first),
                        onTap: () => play(shown[i]),
                      ),
                    ),
                  ],
                  if (tmdb != null) ...[const SizedBox(height: 24), ...tmdbExtraRows(tmdb, firstRow: 5)],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _toggleFavorite(MediaItem item, bool value) async {
    setState(() => _favorite = value);
    try {
      await ref.read(serverClientProvider(widget.serverId))?.setFavorite(item.id, value);
      showToast(value ? '已收藏' : '已取消收藏');
    } catch (e) {
      setState(() => _favorite = !value);
      showToast('操作失败：$e');
    }
  }

  Future<void> _togglePlayed(MediaItem item, bool value) async {
    setState(() => _played = value);
    try {
      await ref.read(serverClientProvider(widget.serverId))?.setPlayed(item.id, value);
      showToast(value ? '已标记为已看' : '已标记为未看');
    } catch (e) {
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

class _SeasonChip extends StatelessWidget {
  const _SeasonChip({required this.node, required this.label, required this.selected, required this.onTap});

  final FocusNode node;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return VFocusable(
      focusNode: node,
      radius: 999,
      scale: 1.05,
      showRing: false,
      onActivate: onTap,
      builder: (context, focused) => AnimatedContainer(
        duration: VMotion.focus,
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 26),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: focused ? Colors.white : (selected ? const Color(0x33FFFFFF) : const Color(0x0DFFFFFF)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: VText.label.copyWith(
            color: focused ? const Color(0xFF0B0C10) : Colors.white,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// 播放资源卡片（效果图：详情页 · 下滑）：版本参数 + 所在服务器与线路延迟
class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.node, required this.option, required this.onTap, this.isDefault = false});

  final FocusNode node;
  final SourceOption option;
  final VoidCallback onTap;
  final bool isDefault;

  @override
  Widget build(BuildContext context) {
    final source = option.source;
    final v = source.video;
    final a = source.audio.firstOrNull;
    final rangeColor = switch (v?.range) {
      VideoRange.dolbyVision => VColors.dolbyVision,
      VideoRange.hdr10 || VideoRange.hdr10Plus || VideoRange.hlg => VColors.rating,
      _ => Colors.white,
    };
    final specs = [
      ?v?.codec?.toUpperCase(),
      if (v?.bitDepth != null) '${v!.bitDepth}bit',
      if (v?.frameRate != null) '${v!.frameRate!.toStringAsFixed(v.frameRate! % 1 == 0 ? 0 : 3)}fps',
      if (a != null)
        '${a.codec?.toUpperCase() ?? ''} ${a.channels == null ? '' : (a.channels! >= 6 ? '${a.channels! - 1}.1' : '${a.channels}.0')}'
            .trim(),
    ].join(' · ');
    final latency = option.latencyMs;
    return VFocusable(
      focusNode: node,
      radius: VRadius.card,
      scale: 1.05,
      onActivate: onTap,
      builder: (context, focused) => AnimatedContainer(
        duration: VMotion.focus,
        width: 420,
        height: 220,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: focused ? const Color(0x29FFFFFF) : const Color(0x12FFFFFF),
          borderRadius: BorderRadius.circular(VRadius.card),
          border: Border.all(color: const Color(0x1FFFFFFF)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${source.resolutionLabel} ${source.rangeLabel}',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: rangeColor),
                ),
                const Spacer(),
                if (isDefault)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999)),
                    child: const Text('默认', style: TextStyle(fontSize: 15, color: Color(0xFF0B0C10))),
                  )
                else
                  Text(
                    source.container.split(',').first.toUpperCase(),
                    style: VText.small.copyWith(color: VColors.textTertiary),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              [
                if (source.size != null) '${(source.size! / 1024 / 1024 / 1024).toStringAsFixed(2)} GB',
                if (source.bitrate != null) '${(source.bitrate! / 1000000).toStringAsFixed(2)} Mbps',
              ].join('   '),
              style: VText.caption,
            ),
            const SizedBox(height: 8),
            Text(
              specs,
              style: VText.small.copyWith(color: VColors.textTertiary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const Spacer(),
            Container(height: 1, color: const Color(0x1AFFFFFF)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    option.serverName,
                    style: VText.small.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (latency != null)
                  Text('$latency ms', style: VText.small.copyWith(color: latency < 150 ? VColors.ok : VColors.warn)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
