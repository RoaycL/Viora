import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/aggregate/tmdb_link.dart';
import '../../data/tmdb/tmdb_client.dart';
import '../../ui/focus/row_focus.dart';
import '../../ui/rows/cards.dart';
import '../../ui/rows/focus_row.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/tmdb_image.dart';
import '../browse/media_cards.dart';
import 'tmdb_cards.dart';

/// TMDB 作品详情：媒体库里没有的作品（首页推荐、人物作品、相似推荐点进来）。
/// 媒体库里有时直接跳到媒体库详情，见 [openTmdbTitle]。
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

class _TmdbDetail extends ConsumerWidget {
  const _TmdbDetail(this.t);

  final TmdbTitle t;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final copies = ref.watch(libraryCopiesProvider(linkKeyOf(t)));
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
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              if (t.rating != null) ...[
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
                                const SizedBox(width: 20),
                              ],
                              Text(
                                copies.isEmpty ? '媒体库暂无资源' : '媒体库有 ${copies.length} 个资源',
                                style: TextStyle(
                                  fontSize: 20,
                                  color: copies.isEmpty ? VColors.textTertiary : const Color(0xFF9AF2B8),
                                ),
                              ),
                            ],
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
                      children: [
                        if (copies.isNotEmpty)
                          (node) => PillButton(
                            focusNode: node,
                            large: true,
                            icon: Icons.play_arrow_rounded,
                            label: '去媒体库播放',
                            onPressed: () => context.push('/item/${copies.first.serverId}/${copies.first.id}'),
                          ),
                        (node) => PillButton(
                          focusNode: node,
                          large: copies.isEmpty,
                          icon: Icons.search_rounded,
                          label: '在媒体库中搜索',
                          onPressed: () => context.go('/search?q=${Uri.encodeComponent(t.title)}'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 48),
                  ...tmdbExtraRows(t, firstRow: 1),
                ],
              ),
            ),
          ),
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
