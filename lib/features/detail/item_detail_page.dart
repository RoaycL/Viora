import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/media/media_models.dart';
import '../../data/media/server_registry.dart';
import '../../data/tmdb/tmdb_client.dart';
import '../../ui/focus/focusable.dart';
import '../../ui/focus/row_focus.dart';
import '../../ui/rows/cards.dart';
import '../../ui/rows/focus_row.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/server_image.dart';
import '../../ui/widgets/toast.dart';
import '../browse/media_cards.dart';

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

final _sourcesProvider = FutureProvider.family<List<MediaSourceInfo>, _Key>((ref, k) async {
  final c = ref.watch(serverClientProvider(k.serverId));
  if (c == null) return const [];
  return (await c.playbackInfo(k.itemId)).sources;
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
  bool? _favorite;
  bool? _played;

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
    final sources = item.playable ? ref.watch(_sourcesProvider(_key)).value ?? const <MediaSourceInfo>[] : const [];

    final zh = localizedMeta(ref, item);
    final favorite = _favorite ?? item.favorite;
    final played = _played ?? item.played;
    final playTarget = isSeries ? (nextUp ?? episodes.firstOrNull) : item;
    final resumeAt = playTarget?.position ?? Duration.zero;
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
            maxWidth: 1920,
            fallbackSeed: item.id,
            alignment: Alignment.topRight,
          ),
        ),
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                stops: [0, 0.32, 0.62, 1],
                colors: [Color(0xFA07080B), Color(0xE607080B), Color(0x5907080B), Color(0x1407080B)],
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
                          onPressed: playTarget == null ? null : () => playMediaItem(context, playTarget),
                        ),
                        if (resumeAt > Duration.zero)
                          (node) => PillButton(
                            focusNode: node,
                            icon: Icons.replay_rounded,
                            label: '从头播放',
                            onPressed: () => playMediaItem(context, playTarget!, fromStart: true),
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
                  if (sources.isNotEmpty)
                    FocusRow(
                      rowIndex: 3,
                      leading: VSpace.safeH,
                      title: '播放资源 · ${sources.length} 个版本',
                      itemCount: sources.length,
                      itemExtent: 400,
                      height: 200,
                      itemBuilder: (context, i, node) => _SourceCard(
                        node: node,
                        source: sources[i],
                        onTap: () => context.push(
                          '/play/${widget.serverId}/${item.id}?pos=${item.position.inMilliseconds}&source=${sources[i].id}',
                        ),
                      ),
                    ),
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
    final text = Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: VText.display.copyWith(fontSize: title.length > 8 ? 72 : 100, letterSpacing: 2),
    );
    // 标题已换成中文时不用（通常是英文的）Logo 图
    if (item.logo == null || item.kind == MediaKind.episode || title != item.name) return text;
    return SizedBox(
      height: 160,
      width: 640,
      child: ServerImage(
        serverId: serverId,
        image: item.logo,
        maxWidth: 800,
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

/// 播放资源卡片（效果图：详情页 · 下滑）
class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.node, required this.source, required this.onTap});

  final FocusNode node;
  final MediaSourceInfo source;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
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
    return VFocusable(
      focusNode: node,
      radius: 22,
      scale: 1.05,
      onActivate: onTap,
      builder: (context, focused) => AnimatedContainer(
        duration: VMotion.focus,
        width: 400,
        height: 200,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: focused ? const Color(0x29FFFFFF) : const Color(0x12FFFFFF),
          borderRadius: BorderRadius.circular(22),
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
            Text(
              source.name ?? '',
              style: VText.small.copyWith(color: VColors.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
