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
import '../../player/preload.dart';

/// 首页（docs/05-metadata-and-segments.md §2.1、docs/06-ui-design.md §4）：
/// Hero（TMDB 今日趋势）+ 继续观看（各服务器）+ 最近入库 + TMDB 推荐行，背景跟随焦点。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => const RowFocusScope(child: _HomeBody());
}

/// 背景：占位渐变 + 真实图片；[hero] 为焦点在推荐行上时 Hero 区显示的预览信息
@immutable
class _Backdrop {
  const _Backdrop(this.key, this.art, [this.image, this.hero]);

  final Object key;
  final ArtSpec art;
  final Widget? image;
  final HeroEntry? hero;
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

  /// 焦点 / 鼠标停在推荐行的某部作品上时，Hero 区显示它的信息（与背景一致）
  HeroEntry? _preview;

  /// 鼠标停在多少张作品卡片上（0 = 不在任何作品上）
  int _hovered = 0;
  Timer? _hoverReset;

  /// 鼠标移开、没有停在任何作品上时，背景和 Hero 恢复默认轮播
  Widget _hoverTrack(Widget child) => MouseRegion(
    onEnter: (_) {
      _hovered++;
      _hoverReset?.cancel();
    },
    onExit: (_) {
      _hovered = (_hovered - 1).clamp(0, 1 << 20);
      if (_hovered > 0) return;
      _hoverReset?.cancel();
      _hoverReset = Timer(const Duration(milliseconds: 300), () {
        if (!mounted || _hovered > 0 || !InputMode.pointer) return;
        _backdropDebounce?.cancel();
        if (_preview != null || _backdrop != null) {
          setState(() {
            _preview = null;
            _backdrop = null;
          });
        }
      });
    },
    child: child,
  );

  /// 焦点在"继续观看"卡片上停留 0.8 秒后预加载（按 OK 后起播更快）
  Timer? _preloadDebounce;

  void _preloadResume(MediaItem it) {
    _preloadDebounce?.cancel();
    _preloadDebounce = Timer(const Duration(milliseconds: 800), () {
      final client = ref.read(serverClientProvider(it.serverId));
      if (client != null) PlaybackPreloader.preload(client, it);
    });
  }

  @override
  void dispose() {
    _backdropDebounce?.cancel();
    _preloadDebounce?.cancel();
    _hoverReset?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// 背景（和 Hero 预览）切换加防抖，避免快速移动 / 鼠标划过时频繁闪烁。
  void _setBackdrop(_Backdrop b) {
    _backdropDebounce?.cancel();
    _backdropDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      if (b.key != _backdrop?.key || b.hero?.key != _preview?.key) {
        setState(() {
          _backdrop = b;
          _preview = b.hero;
        });
      }
    });
  }

  /// TMDB 推荐只做展示：不在首页查媒体库资源，进详情页再到各服务器搜索（docs/04-aggregation.md §7）
  HeroEntry _tmdbHero(TmdbTitle t, String badge) => HeroEntry(
    key: t.key,
    title: t.title,
    latinTitle: t.originalTitle,
    art: placeholderArt(t.key),
    logo: _TmdbLogo(t),
    badge: badge,
    kindLabel: t.isTv ? '剧集' : '电影',
    year: t.year,
    genres: t.genreNames,
    rating: t.rating,
    overview: t.overview,
    onDetail: () => openTmdbTitle(context, t),
  );

  /// 首页只做展示：不显示跨服务器的资源数（在详情页里看，docs/04-aggregation.md §7）
  HeroEntry _itemHero(MediaItem it, String badge, {String? server}) {
    final episode = it.kind == MediaKind.episode;
    final logo = episode ? null : it.logo;
    return HeroEntry(
      key: 'item:${it.serverId}/${it.id}',
      title: episode ? (it.seriesName ?? it.name) : it.name,
      latinTitle: episode ? [?it.episodeLabel, it.name].join('  ') : it.originalTitle,
      art: placeholderArt(it.id),
      logo: logo == null
          ? null
          : ServerImage(
              serverId: it.serverId,
              image: logo,
              width: 620,
              fit: BoxFit.contain,
              alignment: Alignment.bottomLeft,
              transparentFallback: true,
            ),
      badge: badge,
      kindLabel: [
        switch (it.kind) {
          MediaKind.series => '剧集',
          MediaKind.episode => '单集',
          _ => '电影',
        },
        ?server,
      ].join(' · '),
      year: it.year,
      genres: it.genres,
      rating: it.rating != null && it.rating! > 0 ? it.rating : null,
      overview: it.overview ?? '',
      onPlay: it.playable
          ? () => playMediaItem(context, it)
          : it.kind == MediaKind.series
          ? () => openMediaItem(context, it)
          : null,
      onDetail: () => openMediaItem(context, it),
    );
  }

  _Backdrop _tmdbBackdrop(TmdbTitle t, {String? badge}) => _Backdrop(
    t.key,
    placeholderArt(t.key),
    t.backdropPath == null
        ? null
        : TmdbImage(
            path: t.backdropPath,
            kind: TmdbImageKind.backdrop,
            width: 1920,
            fallbackSeed: t.key,
            transparentFallback: true,
          ),
    badge == null ? null : _tmdbHero(t, badge),
  );

  _Backdrop _itemBackdrop(MediaItem it, {String? badge, String? server}) {
    final img = it.backdrop ?? it.thumb;
    return _Backdrop(
      '${it.serverId}/${it.id}',
      placeholderArt(it.id),
      img == null ? null : ServerImage(serverId: it.serverId, image: img, width: 1920, transparentFallback: true),
      badge == null ? null : _itemHero(it, badge, server: server),
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
    final heroes = [
      for (final t in trending.where((t) => t.backdropPath != null).take(8)) (_tmdbHero(t, '今日趋势'), _tmdbBackdrop(t)),
    ];
    if (heroes.isNotEmpty) return heroes;
    // 没有 TMDB：用媒体库最近入库
    return [
      for (final g in recent.where((g) => g.primary.backdrop != null).take(8))
        (_itemHero(g.primary, '最近入库'), _itemBackdrop(g.primary)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(configProvider.select((c) => c.servers));
    final tmdbOn = ref.watch(tmdbClientProvider) != null;
    final serverNames = {for (final s in servers) s.id: s.displayName};
    final resumeAsync = ref.watch(resumeProvider);
    final resume = servers.isEmpty ? const <MediaItem>[] : dedupeWatched(resumeAsync.value ?? const <MediaItem>[]);
    final resumeLoading = servers.isNotEmpty && resumeAsync.isLoading && resume.isEmpty;
    final recent = ref.watch(recentlyAddedProvider);
    List<TmdbTitle> row(TmdbRow r) => ref.watch(tmdbRowProvider(r)).value ?? const [];
    bool rowLoading(TmdbRow r) => tmdbOn && ref.watch(tmdbRowProvider(r)).isLoading;
    final heroes = _heroes(row(TmdbRow.trendingDay), recent);
    final heroLoading = rowLoading(TmdbRow.trendingDay) || (servers.isNotEmpty && !tmdbOn && recent.isEmpty);
    final peopleAsync = ref.watch(tmdbPeopleProvider);
    final people = peopleAsync.value ?? const <TmdbPerson>[];
    final heroIndex = heroes.isEmpty ? 0 : _heroIndex % heroes.length;
    final preview = _preview;
    final backdrop = _backdrop ?? (heroes.isEmpty ? null : heroes[heroIndex].$2);
    // 没配置 TMDB 时，推荐行显示占位并说明
    const tmdbHint = '配置 TMDB 后显示（设置 → 元数据）';

    Widget tmdbRow(int index, String title, TmdbRow r) {
      if (!tmdbOn) return _SkeletonRow(title: title, note: tmdbHint, animate: false);
      if (rowLoading(r)) return _SkeletonRow(title: title);
      return _tmdbRow(index, title, row(r));
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
                  return ColoredBox(color: VColors.background.withValues(alpha: (offset / 500).clamp(0.0, 1.0) * 0.45));
                },
              ),
            ),
          ),
          Positioned.fill(
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.only(bottom: 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (heroes.isNotEmpty || preview != null)
                    HomeHero(
                      key: _heroKey,
                      rowIndex: 0,
                      items: preview != null ? [preview] : [for (final h in heroes) h.$1],
                      index: preview != null ? 0 : heroIndex,
                      showDots: preview == null,
                      autoRotate: preview == null,
                      onIndexChanged: (i) {
                        setState(() {
                          _heroIndex = i;
                          _preview = null;
                        });
                        _setBackdrop(heroes[i % heroes.length].$2);
                      },
                      onFocused: () {
                        // 遥控器 / 键盘回到 Hero：恢复轮播；鼠标从卡片移到 Hero 按钮上：保留预览，按钮作用于刚才那部作品
                        if (InputMode.shouldAutoScroll) {
                          if (heroes.isNotEmpty) {
                            setState(() => _preview = null);
                            _setBackdrop(heroes[heroIndex].$2);
                          }
                          _scroll.animateTo(0, duration: VMotion.scroll, curve: Curves.easeOutCubic);
                        }
                      },
                    )
                  else if (heroLoading)
                    const _HeroSkeleton()
                  else
                    _Welcome(hasServers: servers.isNotEmpty, tmdbOn: tmdbOn),
                  if (resumeLoading)
                    const _SkeletonRow(title: '继续观看', landscape: true)
                  else if (resume.isNotEmpty)
                    FocusRow(
                      rowIndex: 1,
                      title: '继续观看',
                      itemCount: resume.length,
                      itemExtent: LandscapeCard.width,
                      height: LandscapeCard.height,
                      onItemFocused: (i) {
                        final server = serverNames[resume[i].serverId] ?? '未知服务器';
                        _setBackdrop(_itemBackdrop(resume[i], badge: '继续观看', server: server));
                        _preloadResume(resume[i]);
                      },
                      itemBuilder: (context, i, node) => _hoverTrack(
                        mediaLandscapeCard(
                          context,
                          resume[i],
                          node,
                          // 和 Rex 一致：图上"看到 26:16"，下面"5 小时前 · 服务器名"
                          watchedOn: serverNames[resume[i].serverId] ?? '未知服务器',
                          onMenu: () => openMediaItem(context, resume[i]),
                        ),
                      ),
                    ),
                  if (recent.isNotEmpty)
                    FocusRow(
                      rowIndex: 2,
                      title: '最近入库',
                      itemCount: recent.length,
                      itemExtent: PosterCard.width,
                      height: PosterCard.height,
                      onItemFocused: (i) => _setBackdrop(
                        _itemBackdrop(
                          recent[i].primary,
                          badge: '最近入库',
                          server: serverNames[recent[i].primary.serverId],
                        ),
                      ),
                      itemBuilder: (context, i, node) => _hoverTrack(mediaPosterCard(context, recent[i].primary, node)),
                    ),
                  tmdbRow(3, '正在热映', TmdbRow.nowPlaying),
                  tmdbRow(4, '正在播出', TmdbRow.onTheAir),
                  tmdbRow(5, '本周趋势', TmdbRow.trendingWeek),
                  tmdbRow(6, '今日动漫', TmdbRow.animeToday),
                  if (!tmdbOn)
                    const _SkeletonRow(title: '热门人物', note: tmdbHint, circle: true, animate: false)
                  else if (peopleAsync.isLoading && people.isEmpty)
                    const _SkeletonRow(title: '热门人物', circle: true)
                  else if (people.isNotEmpty)
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
                            kind: TmdbImageKind.logo,
                            width: 190,
                            fit: BoxFit.contain,
                            transparentFallback: true,
                            color: Colors.white,
                          ),
                          onActivate: () => context.push('/tmdb/network/${n.id}?name=${Uri.encodeComponent(n.name)}'),
                        );
                      },
                    ),
                  tmdbRow(9, '高分剧集', TmdbRow.topRatedTv),
                  const _EndOfPage(),
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
      onItemFocused: (i) => _setBackdrop(_tmdbBackdrop(items[i], badge: title)),
      itemBuilder: (context, i, node) => _hoverTrack(TmdbPosterCard(title: items[i], node: node)),
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
    // 与详情页一致：固定字号（短标题 100、长标题 72），最多两行
    final text = Text(
      title.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: VText.titleFor(title.title).copyWith(
        shadows: const [Shadow(color: Color(0x73000000), blurRadius: 40, offset: Offset(0, 6))],
      ),
    );
    if (logo == null) return text;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620, maxHeight: 150),
      child: TmdbImage(
        path: logo,
        kind: TmdbImageKind.logo,
        width: 620,
        fit: BoxFit.contain,
        alignment: Alignment.bottomLeft,
        fallback: text,
      ),
    );
  }
}

/// 首次使用 / 未配置：占据 Hero 区，结构和正常首页一致（右上角状态栏、左侧说明与按钮）
class _Welcome extends StatelessWidget {
  const _Welcome({required this.hasServers, required this.tmdbOn});

  final bool hasServers;
  final bool tmdbOn;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: HomeHero.heightOf(context),
      child: Stack(
        children: [
          const Positioned(right: VSpace.safeH, top: VSpace.safeV, child: StatusBar()),
          Positioned(
            left: VSpace.contentLeft,
            bottom: HomeHero.buttonsBottom,
            width: 980,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0x24FFFFFF),
                    borderRadius: BorderRadius.circular(VRadius.xs),
                  ),
                  child: const Text('开始使用', style: TextStyle(fontSize: 20, letterSpacing: 1)),
                ),
                const SizedBox(height: 22),
                const Text('欢迎使用 Viora', style: VText.display),
                const SizedBox(height: 22),
                Text(
                  [
                    if (!hasServers) '添加 Emby / Jellyfin 服务器后，这里会显示继续观看和最近入库。',
                    if (!tmdbOn) '配置 TMDB 后会显示今日趋势、正在热映等推荐，并标注你的媒体库里有没有资源。',
                  ].join('\n'),
                  style: VText.body.copyWith(color: const Color(0xC7FFFFFF), height: 1.7),
                ),
                const SizedBox(height: 40),
                FocusButtonRow(
                  rowIndex: 0,
                  spacing: 32,
                  autoScroll: false,
                  children: [
                    if (!hasServers)
                      (node) => PillButton(
                        focusNode: node,
                        autofocus: true,
                        large: true,
                        icon: Icons.add_rounded,
                        label: '添加服务器',
                        onPressed: () => context.go('/library/add'),
                      ),
                    if (!tmdbOn)
                      (node) => PillButton(
                        focusNode: node,
                        autofocus: hasServers,
                        large: hasServers,
                        icon: Icons.movie_filter_outlined,
                        label: '设置 TMDB',
                        onPressed: () => context.go('/settings'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 加载中的 Hero 占位：和真实 Hero 同样的位置与尺寸
class _HeroSkeleton extends StatelessWidget {
  const _HeroSkeleton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: HomeHero.heightOf(context),
      child: Stack(
        children: [
          const Positioned(right: VSpace.safeH, top: VSpace.safeV, child: StatusBar()),
          Positioned(
            left: VSpace.contentLeft,
            bottom: HomeHero.buttonsBottom,
            width: 900,
            child: _Shimmer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _block(160, 32),
                  const SizedBox(height: 40),
                  _block(560, 110),
                  const SizedBox(height: 40),
                  _block(360, 26),
                  const SizedBox(height: 30),
                  _block(780, 24),
                  const SizedBox(height: 14),
                  _block(620, 24),
                  const SizedBox(height: 50),
                  Row(children: [_block(220, 68, radius: 34), const SizedBox(width: 40), _block(170, 60, radius: 30)]),
                ],
              ),
            ),
          ),
          Positioned(
            left: VSpace.contentLeft,
            bottom: 24,
            child: Text('正在加载推荐…', style: VText.caption.copyWith(color: VColors.textTertiary)),
          ),
        ],
      ),
    );
  }
}

Widget _block(double w, double h, {double radius = 10}) => Container(
  width: w,
  height: h,
  decoration: BoxDecoration(color: const Color(0x1FFFFFFF), borderRadius: BorderRadius.circular(radius)),
);

/// 推荐行占位：加载中时呼吸闪烁；未配置时静态并显示说明
class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow({
    required this.title,
    this.note,
    this.landscape = false,
    this.circle = false,
    this.animate = true,
  });

  final String title;
  final String? note;
  final bool landscape;
  final bool circle;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final w = circle ? PersonCard.size : (landscape ? LandscapeCard.width : PosterCard.width);
    final h = circle ? PersonCard.size : (landscape ? LandscapeCard.imageHeight : PosterCard.imageHeight);
    final cards = Row(
      children: [
        for (var i = 0; i < 9; i++) ...[
          Column(
            crossAxisAlignment: circle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              _block(w, h, radius: circle ? w / 2 : VRadius.card),
              const SizedBox(height: 14),
              _block(circle ? w * 0.7 : w * 0.75, 20, radius: 6),
            ],
          ),
          SizedBox(width: circle ? 40 : VSpace.rowGap),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(left: VSpace.contentLeft, top: 28, bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(title, style: VText.rowTitle.copyWith(color: const Color(0xEBFFFFFF))),
              const SizedBox(width: 16),
              Text(note ?? '加载中…', style: VText.caption.copyWith(color: VColors.textTertiary)),
            ],
          ),
          const SizedBox(height: 20),
          ClipRect(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: animate ? _Shimmer(child: cards) : Opacity(opacity: 0.6, child: cards),
            ),
          ),
        ],
      ),
    );
  }
}

/// 占位的呼吸动画
class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child});

  final Widget child;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween(begin: 0.45, end: 1.0).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
    child: widget.child,
  );
}

/// 首页结尾：滚到底时提示已经到底，而不是一大片空白
class _EndOfPage extends StatelessWidget {
  const _EndOfPage();

  @override
  Widget build(BuildContext context) {
    const line = Expanded(child: Divider(color: Color(0x1FFFFFFF), height: 1));
    return Padding(
      padding: const EdgeInsets.fromLTRB(VSpace.contentLeft, 48, VSpace.safeH, 24),
      child: Row(
        children: [
          line,
          const SizedBox(width: 20),
          Text('已经到底了', style: VText.caption.copyWith(color: VColors.textTertiary)),
          const SizedBox(width: 20),
          line,
        ],
      ),
    );
  }
}
