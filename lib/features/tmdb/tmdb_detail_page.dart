import '../../ui/widgets/end_of_page.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/aggregate/sources.dart';
import '../../data/aggregate/tmdb_link.dart';
import '../../data/config/config_store.dart';
import '../../data/media/media_models.dart';
import '../../data/tmdb/tmdb_client.dart';
import '../../ui/focus/row_focus.dart';
import '../../ui/rows/cards.dart';
import '../../ui/rows/focus_row.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/tmdb_image.dart';
import '../../ui/focus/focusable.dart';
import '../browse/media_cards.dart';
import '../detail/source_widgets.dart';
import '../library/library_page.dart' show ServerTypeLogo;
import 'tmdb_cards.dart';

/// TMDB 作品详情：媒体库里没有的作品（首页推荐、人物作品、相似推荐点进来）。
/// 进入后才到各服务器搜索资源（[tmdbLibrarySearchProvider]），找到时可直接播放或选择资源。
class TmdbDetailPage extends ConsumerWidget {
  const TmdbDetailPage({super.key, required this.isTv, required this.id});

  final bool isTv;
  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tmdbTitleProvider((isTv: isTv, id: id)));
    return Material(
      color: VColors.background,
      child: switch (async) {
        AsyncData(value: final t?) => _TmdbDetail(t),
        AsyncData() => const _Message('没有配置 TMDB'),
        AsyncError(:final error) => _Message(
          '加载失败：$error',
          onRetry: () => ref.invalidate(tmdbTitleProvider((isTv: isTv, id: id))),
        ),
        _ => const Center(child: Text('加载中…', style: VText.label)),
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text, style: VText.label.copyWith(color: VColors.textSecondary)),
        const SizedBox(height: 24),
        PillButton(
          autofocus: true,
          icon: onRetry == null ? Icons.arrow_back_rounded : Icons.refresh_rounded,
          label: onRetry == null ? '返回' : '重试',
          onPressed: onRetry ?? () => context.pop(),
        ),
      ],
    ),
  );
}

class _TmdbDetail extends ConsumerStatefulWidget {
  const _TmdbDetail(this.t);

  final TmdbTitle t;

  @override
  ConsumerState<_TmdbDetail> createState() => _TmdbDetailState();
}

class _TmdbDetailState extends ConsumerState<_TmdbDetail> {
  /// 选中的版本（[sourceKeyOf]）；没选时用排在第一的
  String? _sourceKey;

  void _play(SourceOption o) {
    rememberSource(o.item, o.serverId);
    context.push(o.playRoute(position: o.item.position));
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    // 进入详情页才到各服务器搜索资源；电影再取每个副本的所有版本
    final search = ref.watch(tmdbLibrarySearchProvider(searchKeyOf(t)));
    final copies = search.value ?? const <MediaItem>[];
    final optionsAsync = t.isTv ? null : ref.watch(tmdbSourceOptionsProvider(searchKeyOf(t)));
    final options = optionsAsync?.value ?? const <SourceOption>[];
    final loading = search.isLoading || (optionsAsync?.isLoading ?? false);
    final selected = options.where((o) => sourceKeyOf(o) == _sourceKey).firstOrNull ?? options.firstOrNull;
    final hasServers = ref.watch(configProvider.select((c) => c.servers.isNotEmpty));
    final emptyText = hasServers ? '暂未找到资源' : '还没有添加服务器';
    final found = t.isTv ? copies.isNotEmpty : selected != null;
    final resumeAt = selected?.item.position ?? Duration.zero;
    final meta = [
      t.isTv ? '剧集' : '电影',
      if (t.year != null) '${t.year}',
      if (t.genreNames.isNotEmpty) t.genreNames.take(3).join(' / '),
      if (!t.isTv && t.runtimeMinutes != null) formatDuration(Duration(minutes: t.runtimeMinutes!)),
      if (t.isTv && t.seasons != null) '${t.seasons} 季',
    ].join('  •  ');
    final title = Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: VText.titleFor(t.title));

    return Stack(
      children: [
        Positioned.fill(
          child: TmdbImage(
            path: t.backdropPath,
            kind: TmdbImageKind.backdrop,
            width: 1920,
            fallbackSeed: t.key,
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
              padding: const EdgeInsets.only(top: 130, bottom: 24),
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
                          if (t.logoPath != null)
                            SizedBox(
                              height: 160,
                              width: 640,
                              child: TmdbImage(
                                path: t.logoPath,
                                kind: TmdbImageKind.logo,
                                width: 640,
                                fit: BoxFit.contain,
                                alignment: Alignment.centerLeft,
                                transparentFallback: true,
                              ),
                            )
                          else
                            title,
                          if (t.originalTitle != null && t.originalTitle != t.title) ...[
                            const SizedBox(height: 10),
                            Text(t.originalTitle!, style: VText.label.copyWith(color: VColors.textSecondary)),
                          ],
                          const SizedBox(height: 22),
                          Text(meta, style: const TextStyle(fontSize: 22, color: Color(0xD1FFFFFF))),
                          if (t.rating != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 14),
                              child: Row(
                                children: [
                                  const Icon(Icons.star_rounded, color: VColors.rating, size: 26),
                                  const SizedBox(width: 6),
                                  Text(
                                    t.rating!.toStringAsFixed(1),
                                    style: const TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.w600,
                                      color: VColors.rating,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text('TMDB', style: VText.small.copyWith(color: VColors.textTertiary)),
                                ],
                              ),
                            ),
                          if (t.tagline != null) ...[
                            const SizedBox(height: 18),
                            Text(t.tagline!, style: VText.label.copyWith(fontStyle: FontStyle.italic)),
                          ],
                          if (t.overview.isNotEmpty) ...[
                            const SizedBox(height: 18),
                            Text(
                              t.overview,
                              maxLines: 4,
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
                      scrollToTop: true,
                      children: [
                        // 查找中、没找到时按钮也在：遥控器焦点停在这里，页面不会滚到演职员行把标题顶出屏幕
                        (node) => PillButton(
                          focusNode: node,
                          large: true,
                          busy: loading && !found,
                          icon: found ? Icons.play_arrow_rounded : Icons.block_rounded,
                          label: found
                              ? (t.isTv
                                    ? '去选集观看'
                                    : resumeAt > Duration.zero
                                    ? '继续 · ${formatClock(resumeAt)}'
                                    : '播放')
                              : loading
                              ? '正在加载'
                              : '暂无可播放资源',
                          onPressed: !found
                              ? null
                              : t.isTv
                              ? () => context.push('/item/${copies.first.serverId}/${copies.first.id}')
                              : () => _play(selected!),
                        ),
                        if (!t.isTv && selected != null && resumeAt > Duration.zero)
                          (node) => PillButton(
                            focusNode: node,
                            icon: Icons.replay_rounded,
                            label: '从头播放',
                            onPressed: () {
                              rememberSource(selected.item, selected.serverId);
                              context.push(selected.playRoute());
                            },
                          ),
                        if (!t.isTv && selected != null)
                          (node) => CircleIconButton(
                            focusNode: node,
                            icon: Icons.video_library_outlined,
                            tooltip: '媒体库详情',
                            onPressed: () => context.push('/item/${selected.serverId}/${selected.item.id}'),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 48),
                  if (t.isTv)
                    _SeriesCopies(copies: copies, loading: loading, emptyText: emptyText)
                  else
                    SourcesSection(
                      options: options,
                      loading: loading,
                      selected: selected,
                      onSelect: (o) => setState(() => _sourceKey = sourceKeyOf(o)),
                      onPlay: _play,
                      firstRow: 1,
                      emptyText: emptyText,
                    ),
                  const SizedBox(height: 24),
                  ...tmdbExtraRows(t, firstRow: 1 + SourcesSection.rows),
                  const EndOfPage(leading: VSpace.safeH),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 剧集：各服务器上找到的这部剧，点进媒体库详情页选集
class _SeriesCopies extends ConsumerWidget {
  const _SeriesCopies({required this.copies, required this.loading, required this.emptyText});

  final List<MediaItem> copies;
  final bool loading;
  final String emptyText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(configProvider.select((c) => c.servers));
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(VSpace.safeH, 0, VSpace.safeH, 18),
      child: Text('播放资源', style: VText.rowTitle.copyWith(color: const Color(0xEBFFFFFF))),
    );
    if (copies.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          if (loading)
            const SourceSkeletonRow()
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: VSpace.safeH),
              child: Text(emptyText, style: VText.label.copyWith(color: VColors.textTertiary)),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        FocusRow(
          rowIndex: 1,
          leading: VSpace.safeH,
          itemCount: copies.length,
          itemExtent: SourceCard.width,
          height: SourceCard.height,
          itemBuilder: (context, i, node) {
            final c = copies[i];
            final server = servers.where((s) => s.id == c.serverId).firstOrNull;
            return VFocusable(
              focusNode: node,
              radius: VRadius.card,
              scale: 1.05,
              onActivate: () => context.push('/item/${c.serverId}/${c.id}'),
              builder: (context, focused) => AnimatedContainer(
                duration: VMotion.focus,
                width: SourceCard.width,
                height: SourceCard.height,
                padding: const EdgeInsets.fromLTRB(24, 20, 20, 18),
                decoration: BoxDecoration(
                  color: focused ? const Color(0x29FFFFFF) : const Color(0x12FFFFFF),
                  borderRadius: BorderRadius.circular(VRadius.card),
                  border: Border.all(color: const Color(0x1FFFFFFF)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      [
                        if (c.year != null) '${c.year}',
                        if (c.childCount != null) '${c.childCount} 季',
                        if (c.position > Duration.zero || c.lastPlayed != null) '看过',
                      ].join('   '),
                      style: VText.caption,
                    ),
                    const Spacer(),
                    Container(height: 1, color: const Color(0x1AFFFFFF)),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (server != null) ...[
                          SizedBox.square(dimension: 24, child: ServerTypeLogo(server.type)),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: Text(
                            server?.displayName ?? '服务器',
                            style: VText.small.copyWith(fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Icon(Icons.chevron_right_rounded, color: VColors.textTertiary),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// 演职员 + 相似推荐（TMDB 详情页和媒体库详情页共用）
List<Widget> tmdbExtraRows(TmdbTitle t, {required int firstRow, double leading = VSpace.safeH}) => [
  if (t.cast.isNotEmpty)
    FocusRow(
      rowIndex: firstRow,
      leading: leading,
      title: '演职员',
      itemCount: t.cast.length,
      itemExtent: PersonCard.size,
      gap: 40,
      height: PersonCard.height,
      itemBuilder: (context, i, node) => TmdbPersonCard(person: t.cast[i], node: node),
    ),
  if (t.recommendations.isNotEmpty)
    FocusRow(
      rowIndex: firstRow + 1,
      leading: leading,
      title: '相似推荐',
      itemCount: t.recommendations.length,
      itemExtent: PosterCard.width,
      height: PosterCard.height,
      itemBuilder: (context, i, node) => TmdbPosterCard(title: t.recommendations[i], node: node),
    ),
];
