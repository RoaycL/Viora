import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/input/back_handler.dart';
import '../../app/theme.dart';
import '../../data/aggregate/tmdb_link.dart';
import '../../data/config/config_store.dart';
import '../../data/index/media_index.dart';
import '../../data/media/media_models.dart';
import '../../data/media/server_registry.dart';
import '../../data/tmdb/tmdb_client.dart';
import '../../ui/focus/input_mode.dart';
import '../../ui/focus/row_focus.dart';
import '../../ui/rows/cards.dart';
import '../../ui/rows/focus_row.dart';
import '../../ui/widgets/art.dart';
import '../../ui/widgets/backdrop.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/server_image.dart';
import '../../ui/widgets/status_bar.dart';
import '../../ui/widgets/tmdb_image.dart';
import '../browse/media_cards.dart';
import '../collections/collections_pages.dart';
import '../tmdb/tmdb_cards.dart';
import 'home_hero.dart';

/// 首页（docs/05-metadata-and-segments.md §2.1、docs/06-ui-design.md §4）：
/// Hero（TMDB 今日趋势）+ 继续观看（各服务器）+ 最近入库 + TMDB 推荐行，背景跟随焦点。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => const RowFocusScope(child: _HomeBody());
}

/// 背景：占位渐变 + 真实图片
@immutable
class _Backdrop {
  const _Backdrop(this.key, this.art, [this.image]);

  final Object key;
  final ArtSpec art;
  final Widget? image;
}

class _HomeBody extends ConsumerStatefulWidget {
  const _HomeBody();

  @override
  ConsumerState<_HomeBody> createState() => _HomeBodyState();
}

class _HomeBodyState extends ConsumerState<_HomeBody> {
  final _scroll = ScrollController();
  final _heroKey = GlobalKey<HomeHeroState>();
  int _heroIndex = 0;
  _Backdrop? _backdrop;
  Timer? _backdropDebounce;

  @override
  void dispose() {
    _backdropDebounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// 背景切换加防抖，避免快速移动 / 鼠标划过时背景频繁闪烁。
  void _setBackdrop(_Backdrop b) {
    _backdropDebounce?.cancel();
    _backdropDebounce = Timer(const Duration(milliseconds: 220), () {
      if (mounted && b.key != _backdrop?.key) setState(() => _backdrop = b);
    });
  }

  _Backdrop _tmdbBackdrop(TmdbTitle t) => _Backdrop(
    t.key,
    placeholderArt(t.key),
    t.backdropPath == null
        ? null
        : TmdbImage(path: t.backdropPath, size: 'w1280', fallbackSeed: t.key, transparentFallback: true),
  );

  _Backdrop _itemBackdrop(MediaItem it) {
    final img = it.backdrop ?? it.thumb;
    return _Backdrop(
      '${it.serverId}/${it.id}',
      placeholderArt(it.id),
      img == null ? null : ServerImage(serverId: it.serverId, image: img, maxWidth: 1920, transparentFallback: true),
    );
  }

  bool _onBack() {
    final heroFocused = _heroKey.currentState?.hasFocus ?? false;
    if (_scroll.hasClients && _scroll.offset > 0 || !heroFocused) {
      _scroll.animateTo(0, duration: VMotion.scroll, curve: Curves.easeOutCubic);
      RowFocusScope.of(context).focusRow(0, index: 0);
      return true;
    }
    return false;
  }

  List<(HeroEntry, _Backdrop)> _heroes(List<TmdbTitle> trending, List<AggregatedTitle> recent) {
    final heroes = <(HeroEntry, _Backdrop)>[];
    for (final t in trending.where((t) => t.backdropPath != null).take(8)) {
      final copies = ref.watch(libraryCopiesProvider(linkKeyOf(t)));
      heroes.add((
        HeroEntry(
          key: t.key,
          title: t.title,
          latinTitle: t.originalTitle,
          art: placeholderArt(t.key),
          logo: _TmdbLogo(t),
          badge: '今日趋势',
          kindLabel: t.isTv ? '剧集' : '电影',
          year: t.year,
          genres: t.genreNames,
          rating: t.rating,
          overview: t.overview,
          resources: copies.length,
          // 媒体库里有资源才能播放
          onPlay: copies.isEmpty ? null : () => playTmdbTitle(context, copies.first),
          onDetail: () => openTmdbTitle(context, ref, t),
          onSearch: () => context.go('/search?q=${Uri.encodeComponent(t.title)}'),
        ),
        _tmdbBackdrop(t),
      ));
    }
    if (heroes.isNotEmpty) return heroes;
    // 没有 TMDB：用媒体库最近入库
    return [
      for (final g in recent.where((g) => g.primary.backdrop != null).take(8))
        (
          HeroEntry(
            key: '${g.primary.serverId}/${g.primary.id}',
            title: g.primary.name,
            latinTitle: g.primary.originalTitle,
            art: placeholderArt(g.primary.id),
            logo: g.primary.logo == null
                ? null
                : ServerImage(
                    serverId: g.primary.serverId,
                    image: g.primary.logo,
                    maxWidth: 800,
                    fit: BoxFit.contain,
                    alignment: Alignment.bottomLeft,
                    transparentFallback: true,
                  ),
            badge: '最近入库',
            kindLabel: g.primary.kind == MediaKind.series ? '剧集' : '电影',
            year: g.primary.year,
            genres: g.primary.genres,
            rating: g.primary.rating,
            overview: g.primary.overview ?? '',
            resources: g.copies.length,
            onPlay: () => g.primary.kind == MediaKind.movie
                ? context.push('/play/${g.primary.serverId}/${g.primary.id}?pos=0')
                : openMediaItem(context, g.primary),
            onDetail: () => openMediaItem(context, g.primary),
          ),
          _itemBackdrop(g.primary),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(configProvider.select((c) => c.servers));
    final tmdbOn = ref.watch(tmdbClientProvider) != null;
    final serverNames = {for (final s in servers) s.id: s.name};
    final resume = servers.isEmpty
        ? const <MediaItem>[]
        : dedupeWatched(ref.watch(resumeProvider).value ?? const <MediaItem>[]);
    final recent = ref.watch(recentlyAddedProvider);
    List<TmdbTitle> row(TmdbRow r) => ref.watch(tmdbRowProvider(r)).value ?? const [];
    final heroes = _heroes(row(TmdbRow.trendingDay), recent);
    final heroLoading = tmdbOn && ref.watch(tmdbRowProvider(TmdbRow.trendingDay)).isLoading;
    final people = ref.watch(tmdbPeopleProvider).value ?? const <TmdbPerson>[];
    final heroIndex = heroes.isEmpty ? 0 : _heroIndex % heroes.length;
    final backdrop = _backdrop ?? (heroes.isEmpty ? null : heroes[heroIndex].$2);

    if (heroes.isEmpty && resume.isEmpty && !heroLoading) {
      return _Welcome(hasServers: servers.isNotEmpty, tmdbOn: tmdbOn);
    }

    return BackHandler(
      onBack: _onBack,
      child: Stack(
        children: [
          Positioned.fill(
            child: PageBackdrop(
              art: backdrop?.art ?? const ArtSpec(Color(0xFF1A2233), Color(0xFF07080B), Color(0xFF3A4766)),
              image: backdrop?.image,
              imageKey: backdrop?.key,
            ),
          ),
          // 往下浏览推荐行时整体压暗背景，突出海报
          Positioned.fill(
            child: IgnorePointer(
              child: ListenableBuilder(
                listenable: _scroll,
                builder: (context, _) {
                  final offset = _scroll.hasClients ? _scroll.offset : 0.0;
                  return ColoredBox(color: VColors.background.withValues(alpha: (offset / 500).clamp(0.0, 1.0) * 0.6));
                },
              ),
            ),
          ),
          Positioned.fill(
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.only(bottom: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (heroes.isNotEmpty)
                    HomeHero(
                      key: _heroKey,
                      rowIndex: 0,
                      items: [for (final h in heroes) h.$1],
                      index: heroIndex,
                      onIndexChanged: (i) {
                        setState(() => _heroIndex = i);
                        _setBackdrop(heroes[i % heroes.length].$2);
                      },
                      onFocused: () {
                        _setBackdrop(heroes[heroIndex].$2);
                        if (InputMode.shouldAutoScroll) {
                          _scroll.animateTo(0, duration: VMotion.scroll, curve: Curves.easeOutCubic);
                        }
                      },
                    )
                  else
                    const SizedBox(
                      height: 280,
                      child: Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: EdgeInsets.only(right: VSpace.safeH, top: VSpace.safeV),
                          child: StatusBar(),
                        ),
                      ),
                    ),
                  if (resume.isNotEmpty)
                    FocusRow(
                      rowIndex: 1,
                      title: '继续观看',
                      itemCount: resume.length,
                      itemExtent: LandscapeCard.width,
                      height: LandscapeCard.height,
                      onItemFocused: (i) => _setBackdrop(_itemBackdrop(resume[i])),
                      itemBuilder: (context, i, node) => mediaLandscapeCard(
                        context,
                        resume[i],
                        node,
                        tag: serverNames[resume[i].serverId] ?? '未知服务器',
                        tagIcon: Icons.dns_rounded,
                        onMenu: () => openMediaItem(context, resume[i]),
                      ),
                    ),
                  if (recent.isNotEmpty)
                    FocusRow(
                      rowIndex: 2,
                      title: '最近入库',
                      itemCount: recent.length,
                      itemExtent: PosterCard.width,
                      height: PosterCard.height,
                      onItemFocused: (i) => _setBackdrop(_itemBackdrop(recent[i].primary)),
                      itemBuilder: (context, i, node) =>
                          mediaPosterCard(context, recent[i].primary, node, resources: recent[i].copies.length),
                    ),
                  _tmdbRow(3, '正在热映', row(TmdbRow.nowPlaying)),
                  _tmdbRow(4, '正在播出', row(TmdbRow.onTheAir)),
                  _tmdbRow(5, '本周趋势', row(TmdbRow.trendingWeek)),
                  _tmdbRow(6, '今日动漫', row(TmdbRow.animeToday)),
                  if (people.isNotEmpty)
                    FocusRow(
                      rowIndex: 7,
                      title: '热门人物',
                      itemCount: people.length,
                      itemExtent: PersonCard.size,
                      gap: 40,
                      height: PersonCard.height,
                      itemBuilder: (context, i, node) => TmdbPersonCard(person: people[i], node: node),
                    ),
                  if (tmdbOn)
                    FocusRow(
                      rowIndex: 8,
                      title: '播出平台',
                      itemCount: tmdbNetworks.length,
                      itemExtent: BrandCard.width,
                      height: BrandCard.height,
                      itemBuilder: (context, i, node) {
                        final n = tmdbNetworks[i];
                        return BrandCard(
                          node: node,
                          art: placeholderArt(n.name),
                          name: n.name,
                          logo: TmdbImage(
                            path: n.logoPath,
                            size: 'w300',
                            fit: BoxFit.contain,
                            transparentFallback: true,
                            color: Colors.white,
                          ),
                          onActivate: () => context.push('/tmdb/network/${n.id}?name=${Uri.encodeComponent(n.name)}'),
                        );
                      },
                    ),
                  _tmdbRow(9, '高分剧集', row(TmdbRow.topRatedTv)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tmdbRow(int rowIndex, String title, List<TmdbTitle> items) {
    if (items.isEmpty) return const SizedBox.shrink();
    return FocusRow(
      rowIndex: rowIndex,
      title: title,
      itemCount: items.length,
      itemExtent: PosterCard.width,
      height: PosterCard.height,
      onItemFocused: (i) => _setBackdrop(_tmdbBackdrop(items[i])),
      itemBuilder: (context, i, node) => TmdbPosterCard(title: items[i], node: node),
    );
  }
}

/// Hero 标题 Logo：后台取 TMDB 详情拿 Logo，没有时显示文字标题
class _TmdbLogo extends ConsumerWidget {
  const _TmdbLogo(this.title);

  final TmdbTitle title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logo = ref.watch(tmdbTitleProvider((isTv: title.isTv, id: title.id))).value?.logoPath;
    final text = Text(
      title.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: VText.display.copyWith(
        shadows: const [Shadow(color: Color(0x73000000), blurRadius: 40, offset: Offset(0, 6))],
      ),
    );
    if (logo == null) return text;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620, maxHeight: 150),
      child: TmdbImage(path: logo, size: 'w500', fit: BoxFit.contain, alignment: Alignment.bottomLeft, fallback: text),
    );
  }
}

/// 首次使用：没有服务器、也没有 TMDB
class _Welcome extends StatelessWidget {
  const _Welcome({required this.hasServers, required this.tmdbOn});

  final bool hasServers;
  final bool tmdbOn;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(VSpace.contentLeft, 220, VSpace.safeH, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('欢迎使用 Viora', style: VText.display),
          const SizedBox(height: 20),
          SizedBox(
            width: 900,
            child: Text(
              hasServers
                  ? '媒体库还在同步中。配置 TMDB 后，首页会显示今日趋势、正在热映等推荐，并标注你的媒体库里有没有资源。'
                  : '添加 Emby / Jellyfin 服务器后，这里会显示继续观看和最近入库；配置 TMDB 后还会显示热门推荐。',
              style: VText.body.copyWith(color: VColors.textSecondary),
            ),
          ),
          const SizedBox(height: 48),
          Row(
            children: [
              if (!hasServers) ...[
                PillButton(
                  autofocus: true,
                  large: true,
                  icon: Icons.add_rounded,
                  label: '添加服务器',
                  onPressed: () => context.go('/library/add'),
                ),
                const SizedBox(width: 32),
              ],
              if (!tmdbOn)
                PillButton(
                  autofocus: hasServers,
                  icon: Icons.movie_filter_outlined,
                  label: '设置 TMDB',
                  onPressed: () => context.go('/settings'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
