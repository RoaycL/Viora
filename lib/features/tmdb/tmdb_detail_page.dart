import '../../ui/widgets/end_of_page.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/aggregate/sources.dart';
import '../../data/aggregate/tmdb_link.dart';
import '../../data/config/config_store.dart';
import '../../data/cache/account_scope.dart';
import '../../data/media/media_models.dart';
import '../../data/tmdb/tmdb_client.dart';
import '../../domain/models/external_rating.dart';
import '../../ui/focus/row_focus.dart';
import '../../ui/rows/cards.dart';
import '../../ui/rows/focus_row.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/tmdb_image.dart';
import '../browse/media_cards.dart';
import '../detail/detail_layout.dart';
import '../detail/detail_panels.dart';
import '../detail/episode_catalog.dart';
import '../detail/source_widgets.dart';
import '../metadata/external_ratings.dart';
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
        _ => DetailLoading(seed: '${isTv ? 'tv' : 'movie'}/$id', onBack: () => context.pop()),
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
  final _sources = GlobalKey<SourcesSectionState>();

  /// 选中的版本（[sourceKeyOf]）；没选时用排在第一的
  String? _sourceKey;

  /// 剧集：用户选中的季 / 集（没选时按观看进度自动定位）
  int? _season;
  int? _episode;

  void _play(SourceOption o, {bool fromStart = false}) {
    // 记住这部作品用的服务器（剧集按剧记，下次默认还用这台）
    final copies = ref.read(tmdbLibrarySearchProvider(searchKeyOf(widget.t))).value ?? const <MediaItem>[];
    rememberSource(copies.where((c) => c.serverId == o.serverId).firstOrNull ?? o.item, o.serverId);
    context.push(o.playRoute(position: fromStart ? Duration.zero : o.item.position));
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final key = searchKeyOf(t);
    // 进入详情页才到各服务器搜索资源；电影取每个副本的所有版本，剧集取选中那一集的所有版本
    final search = ref.watch(tmdbLibrarySearchProvider(key));
    final copies = search.isLoading ? const <MediaItem>[] : search.value ?? const <MediaItem>[];
    final libraryEpisodes = t.isTv ? ref.watch(tmdbSeriesEpisodesProvider(key)) : null;
    final episodes = libraryEpisodes?.isLoading == true
        ? const <MediaItem>[]
        : libraryEpisodes?.value ?? const <MediaItem>[];
    final seasons = [...t.seasonList.where((x) => x.number > 0), ...t.seasonList.where((x) => x.number == 0)];
    final start = pickStartEpisode(episodes);
    final season = _season ?? start?.$1 ?? seasons.firstOrNull?.number ?? 1;
    final seasonEps = t.isTv ? ref.watch(tmdbSeasonProvider((tvId: t.id, season: season))).value : null;
    final episode =
        _episode ?? (start != null && start.$1 == season ? start.$2 : null) ?? seasonEps?.firstOrNull?.number ?? 1;
    final optionsAsync = t.isTv
        ? ref.watch(tmdbEpisodeSourcesProvider((title: key, season: season, episode: episode)))
        : ref.watch(tmdbSourceOptionsProvider(key));
    final options = visibleSourceOptions(ref.read(configProvider), optionsAsync.value ?? const <SourceOption>[]);
    final loading = search.isLoading || (libraryEpisodes?.isLoading ?? false) || optionsAsync.isLoading;
    final selected = options.where((o) => sourceKeyOf(o) == _sourceKey).firstOrNull ?? options.firstOrNull;
    final hasServers = ref.watch(configProvider.select((c) => c.servers.isNotEmpty));
    final emptyText = !hasServers
        ? '还没有添加服务器'
        : t.isTv && copies.isNotEmpty
        ? '各服务器上都没有第 $season 季第 $episode 集'
        : '暂未找到资源';
    final found = selected != null;
    final resumeAt = selected?.item.position ?? Duration.zero;
    final epLabel = 'S${season}E$episode';
    String playLabel() {
      if (!found) return loading ? '正在加载' : '暂无可播放资源';
      final what = t.isTv ? ' $epLabel' : '';
      return resumeAt > Duration.zero ? '继续$what · ${formatClock(resumeAt)}' : '播放$what';
    }

    final meta = [
      t.isTv ? '剧集' : '电影',
      if (t.year != null) '${t.year}',
      if (t.genreNames.isNotEmpty) t.genreNames.take(3).join(' / '),
      if (!t.isTv && t.runtimeMinutes != null) formatDuration(Duration(minutes: t.runtimeMinutes!)),
      if (t.isTv && t.seasons != null) '${t.seasons} 季',
    ].join('  •  ');
    final title = Text(
      t.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: DefaultTextStyle.of(context).style.merge(VText.titleFor(t.title)),
    );

    return DetailLayout(
      seed: t.key,
      backdrop: TmdbImage(
        path: t.backdropPath,
        kind: TmdbImageKind.backdrop,
        width: 1920,
        fallbackSeed: t.key,
        alignment: Alignment.topRight,
        transparentFallback: true,
      ),
      info: Column(
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
                fallback: Align(alignment: Alignment.centerLeft, child: title),
                errorFallback: Align(alignment: Alignment.centerLeft, child: title),
              ),
            )
          else
            title,
          if (t.originalTitle != null && t.originalTitle != t.title) ...[
            const SizedBox(height: 10),
            Text(
              t.originalTitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: VText.label.copyWith(color: VColors.textSecondary),
            ),
          ],
          const SizedBox(height: 22),
          Text(meta, style: const TextStyle(fontSize: 22, color: Color(0xD1FFFFFF))),
          ExternalRatings(
            query: RatingQuery(
              kind: t.isTv ? RatingMediaKind.series : RatingMediaKind.movie,
              imdbId: t.imdbId,
              tmdbId: t.id,
            ),
            tmdbRating: t.rating,
          ),
          if (t.tagline != null) ...[
            const SizedBox(height: 18),
            Text(
              t.tagline!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: VText.label.copyWith(fontStyle: FontStyle.italic),
            ),
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
      buttons: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RowAutoFocus(),
          FocusButtonRow(
            rowIndex: 0,
            scrollToTop: true,
            scrollable: true,
            children: [
              // 查找中、没找到时按钮也在：遥控器焦点停在这里，页面不会滚到演职员行把标题顶出屏幕
              (node) => PillButton(
                focusNode: node,
                large: true,
                busy: loading && !found,
                icon: found ? Icons.play_arrow_rounded : Icons.block_rounded,
                label: playLabel(),
                onPressed: !found ? null : () => _play(selected),
              ),
              if (selected != null && resumeAt > Duration.zero)
                (node) => PillButton(
                  focusNode: node,
                  icon: Icons.replay_rounded,
                  label: '从头播放',
                  onPressed: () => _play(selected, fromStart: true),
                ),
              (node) => PillButton(
                focusNode: node,
                icon: Icons.video_library_outlined,
                label: '选择资源',
                onPressed: () => _sources.currentState?.reveal(),
              ),
              if (t.overview.isNotEmpty)
                (node) => Tooltip(
                  message: '完整简介',
                  child: CircleIconButton(
                    focusNode: node,
                    icon: Icons.subject_rounded,
                    tooltip: '完整简介',
                    onPressed: () => showDetailOverview(context, title: t.title, overview: t.overview),
                  ),
                ),
              if (copies.isNotEmpty)
                (node) => CircleIconButton(
                  focusNode: node,
                  icon: Icons.video_library_outlined,
                  tooltip: '媒体库详情',
                  onPressed: () {
                    final c = copies.where((c) => c.serverId == selected?.serverId).firstOrNull ?? copies.first;
                    context.push('/item/${c.serverId}/${c.id}');
                  },
                ),
            ],
          ),
        ],
      ),
      below: [
        const SizedBox(height: 48),
        if (t.isTv && seasons.isNotEmpty) ...[
          if (seasons.length > 1)
            SeasonSelector(
              key: ValueKey(
                ref.watch(configProvider.select((c) => c.servers.map((s) => '${s.id}/${accountScope(s)}').join('|'))),
              ),
              seasons: [for (final s in seasons) (id: s.number, label: s.name)],
              selected: season,
              onSelect: (id) => setState(() {
                _season = id as int;
                _episode = null;
                _sourceKey = null;
              }),
            ),
          _EpisodeRow(
            tvId: t.id,
            season: season,
            selected: episode,
            // 有季切换按钮时按钮就是标题；只有一季时显示季名
            seasonLabel: seasons.length > 1 ? null : seasons.first.name,
            library: episodes,
            // 媒体库里根本没有这部剧时不逐集标「无资源」（下面的播放资源区会说明）
            libraryLoaded: (libraryEpisodes?.hasValue ?? false) && copies.isNotEmpty,
            onSelect: (n) {
              if (n == episode && selected != null) {
                _play(selected);
                return;
              }
              setState(() {
                _season = season;
                _episode = n;
                _sourceKey = null;
              });
            },
          ),
          const SizedBox(height: 24),
        ],
        SourcesSection(
          key: _sources,
          options: options,
          loading: loading,
          selected: selected,
          onSelect: (o) => setState(() => _sourceKey = sourceKeyOf(o)),
          onPlay: _play,
          firstRow: 3,
          caption: t.isTv ? epLabel : null,
          emptyText: emptyText,
        ),
        const SizedBox(height: 24),
        ...tmdbExtraRows(t, firstRow: 3 + SourcesSection.rows),
        const EndOfPage(leading: VSpace.safeH),
      ],
    );
  }
}

/// 剧集：当前季的所有集（TMDB 数据），标出媒体库里有没有、看到哪里；点一下选中，再点一次播放
class _EpisodeRow extends ConsumerWidget {
  const _EpisodeRow({
    required this.tvId,
    required this.season,
    required this.selected,
    required this.library,
    required this.libraryLoaded,
    required this.onSelect,
    this.seasonLabel,
  });

  final int tvId;
  final int season;
  final int selected;
  final List<MediaItem> library;
  final bool libraryLoaded;
  final ValueChanged<int> onSelect;

  /// 只有一季时行标题显示季名
  final String? seasonLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tmdbSeasonProvider((tvId: tvId, season: season)));
    final eps = mergeEpisodeCatalog(async.value ?? const <TmdbEpisode>[], library, season);
    if (eps.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(VSpace.safeH, 8, VSpace.safeH, 8),
        child: Text(
          async.isLoading ? '正在加载剧集…' : '没有找到这一季的剧集信息',
          style: VText.label.copyWith(color: VColors.textTertiary),
        ),
      );
    }
    return EpisodeCatalogRow(
      tvId: tvId,
      season: season,
      episodes: eps,
      selected: selected,
      library: library,
      libraryLoaded: libraryLoaded,
      seasonLabel: seasonLabel,
      onSelect: onSelect,
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
