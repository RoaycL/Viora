import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/input/back_handler.dart';
import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../../data/aggregate/tmdb_link.dart';
import '../../data/config/config_store.dart';
import '../../data/index/media_index.dart';
import '../../data/media/media_models.dart';
import '../../data/media/server_registry.dart';
import '../../data/tmdb/tmdb_client.dart';
import '../../ui/focus/focusable.dart';
import '../../ui/focus/input_mode.dart';
import '../../ui/focus/row_focus.dart';
import '../../ui/rows/cards.dart';
import '../../ui/rows/focus_row.dart';
import '../../ui/widgets/art.dart';
import '../../ui/widgets/backdrop.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/cached_image.dart';
import '../../ui/widgets/end_of_page.dart';
import '../../ui/widgets/image_sizing.dart';
import '../../ui/widgets/server_image.dart';
import '../../ui/widgets/status_bar.dart';
import '../../ui/widgets/tmdb_image.dart';
import '../browse/media_cards.dart';
import '../collections/collections_pages.dart';
import '../tmdb/tmdb_cards.dart';
import 'home_hero.dart';
import 'home_focus.dart';
import 'home_prefetch.dart';
import '../../player/preload.dart';

/// 首页（docs/05-metadata-and-segments.md §2.1、docs/06-ui-design.md §4）：
/// Hero（TMDB 今日趋势）+ 继续观看（各服务器）+ 最近入库 + TMDB 推荐行，背景跟随焦点。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => const _HomeBody();
}

/// 背景：占位渐变 + 真实图片；[hero] 为焦点在推荐行上时 Hero 区显示的预览信息
@immutable
class _Backdrop {
  const _Backdrop(this.key, this.art, [this.image, this.hero, this.provider]);

  final Object key;
  final ArtSpec art;
  final Widget? image;
  final HeroEntry? hero;
  final ImageProvider? provider;
}

class _HomeBody extends ConsumerStatefulWidget {
  const _HomeBody();

  @override
  ConsumerState<_HomeBody> createState() => _HomeBodyState();
}

class _HomeBodyState extends ConsumerState<_HomeBody> {
  static const _recommendationRows = {
    3: TmdbRow.nowPlaying,
    4: TmdbRow.onTheAir,
    5: TmdbRow.trendingWeek,
    6: TmdbRow.animeToday,
    9: TmdbRow.topRatedTv,
  };
  final _scroll = ScrollController();
  final _anchor = FocusScopeNode(debugLabel: 'home-navigation');
  late final _focus = HomeFocusController(anchor: _anchor, revealRow: _revealRow);

  /// 视口外提前挂载的范围：约两行。原来只有 160（不到半行），按方向键下移时整行才开始构建、下载海报
  static const _mountExtent = 900.0;

  /// 各行（Hero 以外）已构建的控件：只有这一行自己的数据变化时才重建。
  /// 焦点移动后切换背景 / Hero 预览会 setState 整个首页；不缓存的话所有已挂载的行和卡片都要跟着重建，
  /// 电视上正好赶在下翻滚动动画中间，表现为「往下滑卡一下」。
  final _rowCache = <int, (Object, Widget)>{};

  WidgetBuilder _cachedRow(int row, Object key, WidgetBuilder build) {
    final hit = _rowCache[row];
    if (hit != null && hit.$1 == key) return (_) => hit.$2;
    // Builder：重新挂载时用新的 context 构建（卡片里的跳转 / 菜单回调不会拿到已销毁的 context）
    final widget = Builder(builder: build);
    _rowCache[row] = (key, widget);
    return (_) => widget;
  }

  final _offsets = <int, double>{};
  final _extents = <int, double>{};
  String? _mediaScope;
  TmdbClient? _prefetchClient;
  HomePrefetchQueue<int>? _dataPrefetch;
  HomePrefetchQueue<ImageProvider>? _imagePrefetch;
  final _prefetchTitles = <int, List<TmdbTitle>>{};
  List<TmdbPerson> _prefetchPeople = const [];
  bool _prefetchScheduled = false;
  ValueListenable<TickerModeData>? _tickerMode;
  final _heroKey = GlobalKey<HomeHeroState>();
  int _heroIndex = 0;
  int? _pendingHeroIndex;
  bool _heroRotationPaused = false;
  _Backdrop? _baseBackdrop;
  int _backdropGeneration = 0;
  List<String> _heroKeys = const [];
  Timer? _backdropDeadline;
  ImageStream? _backdropStream;
  ImageStreamListener? _backdropListener;
  Completer<bool?>? _backdropResult;
  _Backdrop? _backdrop;
  Timer? _backdropDebounce;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_schedulePrefetch);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mode = TickerMode.getValuesNotifier(context);
    if (identical(mode, _tickerMode)) return;
    _tickerMode?.removeListener(_prefetchVisibilityChanged);
    _tickerMode = mode..addListener(_prefetchVisibilityChanged);
  }

  void _prefetchVisibilityChanged() {
    if (_tickerMode?.value.enabled == false) {
      _backdropGeneration++;
      _backdropDebounce?.cancel();
      _cancelBackdropImage();
      _dataPrefetch?.schedule(const []);
      _imagePrefetch?.schedule(const []);
    } else {
      if (_pendingHeroIndex != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _tickerMode?.value.enabled != false) setState(() => _pendingHeroIndex = null);
        });
      }
      _schedulePrefetch();
    }
  }

  void _configurePrefetch(TmdbClient? client) {
    if (identical(client, _prefetchClient)) return;
    _backdropGeneration++;
    _backdropDebounce?.cancel();
    _cancelBackdropImage();
    _pendingHeroIndex = null;
    _backdrop = null;
    _preview = null;
    _dataPrefetch?.dispose();
    _imagePrefetch?.dispose();
    _prefetchTitles.clear();
    _prefetchPeople = const [];
    _prefetchClient = client;
    _dataPrefetch = client == null
        ? null
        : HomePrefetchQueue<int>(
            concurrency: 2,
            load: (row) async {
              if (row == 7) {
                final people = await ref.read(tmdbPeopleProvider.future);
                if (!mounted || !identical(client, _prefetchClient)) return;
                _prefetchPeople = people;
              } else {
                final titles = await ref.read(tmdbRowProvider(_recommendationRows[row]!).future);
                if (!mounted || !identical(client, _prefetchClient)) return;
                _prefetchTitles[row] = titles;
              }
              _schedulePrefetch();
            },
          );
    _imagePrefetch = client == null
        ? null
        : HomePrefetchQueue<ImageProvider>(
            concurrency: PlatformProfile.isTv ? 2 : 4,
            load: (image) => precacheImage(image, context, onError: (_, _) {}),
          );
  }

  void _schedulePrefetch() {
    if (!mounted || _prefetchScheduled) return;
    _prefetchScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _prefetchScheduled = false;
      if (!mounted) return;
      if (_tickerMode?.value.enabled == false || !_scroll.hasClients) {
        _dataPrefetch?.schedule(const []);
        _imagePrefetch?.schedule(const []);
        return;
      }
      final top = _scroll.offset;
      final bottom = top + _scroll.position.viewportDimension;
      // 轻量 JSON 先准备，前方行优先；最多两个后台任务，可见行不受队列阻塞。
      final rows = [..._recommendationRows.keys, 7]
        ..sort((a, b) {
          double priority(int row) => _offsets[row]! >= top ? _offsets[row]! - top : 100000 + top - _offsets[row]!;
          return priority(a).compareTo(priority(b));
        });
      _dataPrefetch?.schedule(rows);
      // 预取接下来两个还没挂载的行的首屏小图，不提前取大背景 / 详情。
      final next = _focus.order.where((row) => _offsets[row]! >= bottom + _mountExtent).take(2);
      _imagePrefetch?.schedule([for (final row in next) ..._rowImages(row)]);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Iterable<ImageProvider> _rowImages(int row) sync* {
    final client = _prefetchClient;
    if (client == null) return;
    final circle = row == 7;
    final brand = row == 8;
    final width = circle ? PersonCard.size : (brand ? BrandCard.width : PosterCard.width);
    final count = ((MediaQuery.sizeOf(context).width - VSpace.contentLeft) / (width + VSpace.rowGap)).ceil().clamp(
      1,
      8,
    );
    final paths = circle
        ? _prefetchPeople.take(count).map((p) => p.profilePath)
        : brand
        ? tmdbNetworks.take(count).map((n) => n.logoPath)
        : (_prefetchTitles[row] ?? const <TmdbTitle>[]).take(count).map((t) => t.posterPath);
    final kind = circle ? TmdbImageKind.profile : (brand ? TmdbImageKind.logo : TmdbImageKind.poster);
    final px = ImageSizing.physicalWidth(context, brand ? 190 : (circle ? PersonCard.size : PosterCard.width));
    for (final path in paths) {
      if (path != null && path.isNotEmpty) yield netImage(client.image(path, size: kind.sizeFor(px)), cacheWidth: px);
    }
  }

  /// 已经准备好（详情、Logo、背景图都已下载解码）的 Hero：轮播只切到准备好的，避免切过去后标题、Logo、背景依次闪出来
  final _readyHeroes = <String>{};
  final _warming = <String>{};
  final _warmStarted = <String, DateTime>{};

  /// 准备好了，或者已经等了 10 秒（网络慢 / 图片下载不下来时不让轮播一直卡住）
  bool _heroReady(String key) {
    if (_readyHeroes.contains(key)) return true;
    final started = _warmStarted[key];
    return started != null && DateTime.now().difference(started) > const Duration(seconds: 10);
  }

  /// 预热当前和下一部：一部一部来，不一次性把 8 张大图塞进电视内存
  Future<void> _warmHeroes(List<TmdbTitle> list, int index) async {
    if (list.isEmpty) return;
    for (final t in [list[index % list.length], list[(index + 1) % list.length]]) {
      if (_readyHeroes.contains(t.key) || !_warming.add(t.key)) continue;
      _warmStarted[t.key] = DateTime.now();
      try {
        final client = ref.read(tmdbClientProvider);
        if (client == null || !mounted) return;
        String? logo;
        try {
          logo = (await ref.read(tmdbTitleProvider((isTv: t.isTv, id: t.id)).future))?.logoPath;
        } catch (_) {}
        if (!mounted) return;
        // 和 TmdbImage 用一样的地址与解码宽度，才能命中同一份图片缓存
        final bg = ImageSizing.physicalWidth(context, 1920);
        final logoPx = ImageSizing.physicalWidth(context, 620);
        await Future.wait([
          if (t.backdropPath != null)
            precacheImage(
              netImage(client.image(t.backdropPath!, size: TmdbImageKind.backdrop.sizeFor(bg)), cacheWidth: bg),
              context,
              onError: (_, _) {},
            ),
          if (logo != null)
            precacheImage(
              netImage(client.image(logo, size: TmdbImageKind.logo.sizeFor(logoPx)), cacheWidth: logoPx),
              context,
              onError: (_, _) {},
            ),
        ]);
      } catch (_) {
      } finally {
        _warming.remove(t.key);
        _readyHeroes.add(t.key);
      }
    }
  }

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
          final target = _baseBackdrop;
          if (target != null) _setBackdrop(target);
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
    _backdropGeneration++;
    _cancelBackdropImage();
    _tickerMode?.removeListener(_prefetchVisibilityChanged);
    _dataPrefetch?.dispose();
    _imagePrefetch?.dispose();
    _backdropDebounce?.cancel();
    _preloadDebounce?.cancel();
    _hoverReset?.cancel();
    _scroll.dispose();
    _focus.dispose();
    _anchor.dispose();
    super.dispose();
  }

  /// 背景（和 Hero 预览）切换加防抖，避免快速移动 / 鼠标划过时频繁闪烁。
  void _cancelBackdropImage() {
    _backdropDeadline?.cancel();
    if (_backdropStream != null && _backdropListener != null) _backdropStream!.removeListener(_backdropListener!);
    if (_backdropResult?.isCompleted == false) _backdropResult!.complete(false);
    _backdropStream = null;
    _backdropListener = null;
    _backdropResult = null;
  }

  /// true：图片已就绪；false：加载失败；null：4 秒还没下载完（慢网络），先切过去，图片下载完再淡入
  Future<bool?> _prepareBackdrop(ImageProvider provider) {
    final result = Completer<bool?>();
    final stream = provider.resolve(createLocalImageConfiguration(context));
    void finish(bool? ready) {
      if (!result.isCompleted) result.complete(ready);
      if (identical(_backdropResult, result)) _cancelBackdropImage();
    }

    final listener = ImageStreamListener((image, _) {
      image.dispose();
      finish(true);
    }, onError: (_, _) => finish(false));
    _backdropResult = result;
    _backdropStream = stream;
    _backdropListener = listener;
    _backdropDeadline = Timer(const Duration(seconds: 4), () => finish(null));
    stream.addListener(listener);
    return result.future;
  }

  void _setBackdrop(_Backdrop b, {VoidCallback? onCommit}) {
    if (onCommit == null && _pendingHeroIndex != null) setState(() => _pendingHeroIndex = null);
    _backdropDebounce?.cancel();
    final generation = ++_backdropGeneration;
    _cancelBackdropImage();
    if (b.key == _backdrop?.key && b.hero?.key == _preview?.key) {
      if (onCommit != null) setState(onCommit);
      return;
    }
    // 电视等焦点停稳一点再换：每次换背景都要下载、解码一张全屏图（遥控器按住方向键时焦点约 150ms 移动一次）
    _backdropDebounce = Timer(Duration(milliseconds: PlatformProfile.isTv ? 350 : 220), () async {
      if (!mounted || _tickerMode?.value.enabled == false) return;
      final imageReady = b.provider == null ? true : await _prepareBackdrop(b.provider!);
      if (!mounted || generation != _backdropGeneration || _tickerMode?.value.enabled == false) return;
      setState(() {
        // 新图就绪前保留旧图与旧信息；失败时显示新作品占位，不能把旧图配给新标题。
        // 超时（null）仍保留图片：下载完成后自动淡入，否则这部作品会一直停在占位上
        _backdrop = imageReady != false ? b : _Backdrop(b.key, b.art, null, b.hero);
        _preview = b.hero;
        onCommit?.call();
      });
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

  _Backdrop _tmdbBackdrop(TmdbTitle t, {String? badge}) {
    final client = ref.read(tmdbClientProvider);
    final px = ImageSizing.physicalWidth(context, 1920);
    return _Backdrop(
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
      client == null || t.backdropPath == null
          ? null
          : netImage(client.image(t.backdropPath!, size: TmdbImageKind.backdrop.sizeFor(px)), cacheWidth: px),
    );
  }

  _Backdrop _itemBackdrop(MediaItem it, {String? badge, String? server}) {
    final img = it.backdrop ?? it.thumb;
    final client = ref.read(serverClientProvider(it.serverId));
    final px = ImageSizing.physicalWidth(context, 1920);
    final request = img == null ? null : client?.image(img, maxWidth: px);
    return _Backdrop(
      '${it.serverId}/${it.id}',
      placeholderArt(it.id),
      img == null ? null : ServerImage(serverId: it.serverId, image: img, width: 1920, transparentFallback: true),
      badge == null ? null : _itemHero(it, badge, server: server),
      request == null ? null : netImage(request.url.toString(), headers: request.headers, cacheWidth: px),
    );
  }

  bool _onBack() {
    if ((_scroll.hasClients && _scroll.offset > 0) || !_focus.atHero) {
      _focus.focusRow(0, index: 0);
      return true;
    }
    return false;
  }

  Future<void> _revealRow(int row) async {
    if (!mounted || !_scroll.hasClients || !_offsets.containsKey(row)) return;
    final viewport = _scroll.position.viewportDimension;
    final target = row == 0 ? 0.0 : _offsets[row]! - (viewport - _extents[row]!) * 0.32;
    final offset = target.clamp(0.0, _scroll.position.maxScrollExtent);
    if ((_scroll.offset - offset).abs() < 1) {
      // 快速反向回到当前位置时，也要停止尚在向旧目标移动的滚动动画。
      if (_scroll.position.isScrollingNotifier.value) _scroll.jumpTo(offset);
      return;
    }
    if (VMotion.reduced(context)) {
      _scroll.jumpTo(offset);
    } else {
      await _scroll.animateTo(offset, duration: VMotion.scroll, curve: Curves.easeOutCubic);
    }
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
    final scope = ref.watch(mediaFeedScopeProvider);
    if (_mediaScope != null && _mediaScope != scope) {
      _backdropGeneration++;
      _cancelBackdropImage();
      _pendingHeroIndex = null;
      _focus.resetMemory();
      _backdropDebounce?.cancel();
      _preloadDebounce?.cancel();
      _preview = null;
      _backdrop = null;
      _rowCache.clear();
    }
    _mediaScope = scope;
    final servers = ref.watch(configProvider.select((c) => c.servers));
    final tmdbClient = ref.watch(tmdbClientProvider);
    final tmdbOn = tmdbClient != null;
    _configurePrefetch(tmdbClient);
    final serverNames = {for (final s in servers) s.id: s.displayName};
    final resumeAsync = ref.watch(resumeProvider);
    final resume = servers.isEmpty ? const <MediaItem>[] : dedupeWatched(resumeAsync.value ?? const <MediaItem>[]);
    final resumeState = ref.watch(mediaFeedStateProvider(MediaFeedKind.resume)).value;
    final recent = ref.watch(recentlyAddedProvider);
    // Hero 是首屏内容；其余行提前准备轻量数据，海报构建仍由可见范围驱动。
    final heroAsync = ref.watch(tmdbRowProvider(TmdbRow.trendingDay));
    final trending = heroAsync.value ?? const <TmdbTitle>[];
    final heroes = _heroes(trending, recent);
    final heroKeys = [for (final h in heroes) h.$1.key];
    if (!listEquals(_heroKeys, heroKeys)) {
      final oldKey = _heroKeys.isEmpty ? null : _heroKeys[_heroIndex % _heroKeys.length];
      final sameTitle = oldKey == null ? -1 : heroKeys.indexOf(oldKey);
      _heroIndex = sameTitle >= 0 ? sameTitle : (heroKeys.isEmpty ? 0 : _heroIndex.clamp(0, heroKeys.length - 1));
      _heroKeys = heroKeys;
      _pendingHeroIndex = null;
      _backdropGeneration++;
      _backdropDebounce?.cancel();
      _cancelBackdropImage();
      if (_preview == null) _backdrop = null;
    }
    final heroTitles = trending.where((t) => t.backdropPath != null).take(8).toList();
    if (heroTitles.isNotEmpty) {
      final next = heroTitles[(_heroIndex + 1) % heroTitles.length].key;
      if (!_readyHeroes.contains(next) && !_warming.contains(next)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _warmHeroes(heroTitles, _heroIndex);
        });
      }
    }
    final heroIndex = heroes.isEmpty ? 0 : _heroIndex % heroes.length;
    _baseBackdrop = heroes.isEmpty ? null : heroes[heroIndex].$2;
    final preview = _preview;
    final backdrop = _backdrop ?? (heroes.isEmpty ? null : heroes[heroIndex].$2);
    final textScale = MediaQuery.textScalerOf(context);
    final posterHeight = math.max(
      PosterCard.height,
      PosterCard.imageHeight + 16 + textScale.scale(22) * 1.5 + textScale.scale(18) * 1.5,
    );
    final landscapeHeight = math.max(
      LandscapeCard.height,
      LandscapeCard.imageHeight + 16 + textScale.scale(22) * 1.5 + textScale.scale(18) * 1.5,
    );
    final peopleHeight = math.max(
      PersonCard.height,
      PersonCard.size + 12 + textScale.scale(20) * 1.5 + textScale.scale(16) * 1.5,
    );
    final header = math.max(48.0, textScale.scale(28) * 1.5);
    double extent(double cards) => header + cards + FocusRow.focusBleed * 2 + 24;
    final showResume =
        servers.isNotEmpty && (resume.isNotEmpty || resumeAsync.isLoading || (resumeState?.failures ?? 0) > 0);
    // 首屏给继续观看留的高度：刷新期间（已有结果、正在重新加载）沿用已有结果，不让 Hero 一缩一放、焦点按钮跳动
    final reserveResume =
        servers.isNotEmpty &&
        (resume.isNotEmpty || (resumeAsync.isLoading && !resumeAsync.hasValue) || (resumeState?.failures ?? 0) > 0);
    final heroHeight = HomeHero.heightOf(context, reserveBelow: reserveResume ? extent(landscapeHeight) : 0);
    final sections = <({int row, double height, WidgetBuilder build})>[
      (
        row: 0,
        height: heroHeight,
        build: (context) {
          if (heroes.isNotEmpty || preview != null) {
            return HomeHero(
              key: _heroKey,
              rowIndex: 0,
              height: heroHeight,
              rotationPaused: _heroRotationPaused,
              onToggleRotation: () => setState(() => _heroRotationPaused = !_heroRotationPaused),
              pendingIndex: _pendingHeroIndex,
              autofocus: _focus.atHero,
              items: preview != null ? [preview] : [for (final h in heroes) h.$1],
              index: preview != null ? 0 : heroIndex,
              showCarousel: preview == null,
              autoRotate: preview == null,
              isReady: heroTitles.isEmpty || heroTitles.length != heroes.length
                  ? null
                  : (i) => _heroReady(heroTitles[i % heroTitles.length].key),
              onIndexChanged: (i) {
                setState(() => _pendingHeroIndex = i);
                _setBackdrop(
                  heroes[i % heroes.length].$2,
                  onCommit: () {
                    _heroIndex = i;
                    _pendingHeroIndex = null;
                  },
                );
              },
              onFocused: () {
                if (!_focus.remember(0, _heroKey.currentState?.rememberedIndex ?? 0)) return;
                if (InputMode.shouldAutoScroll) {
                  if (heroes.isNotEmpty &&
                      _pendingHeroIndex == null &&
                      (_preview != null || _backdrop?.key != heroes[heroIndex].$2.key)) {
                    _setBackdrop(heroes[heroIndex].$2);
                  }
                  _revealRow(0);
                }
              },
            );
          }
          if (!tmdbOn && servers.isEmpty) {
            return _Welcome(hasServers: false, tmdbOn: false, autofocus: _focus.atHero, height: heroHeight);
          }
          if (tmdbOn && heroAsync.hasError) {
            return _HomeRowStatus(
              row: 0,
              height: heroHeight,
              autofocus: _focus.atHero,
              title: '今日推荐',
              note: '推荐加载失败',
              onRetry: () => ref.invalidate(tmdbRowProvider(TmdbRow.trendingDay)),
            );
          }
          if (tmdbOn && heroAsync.isLoading) {
            return _HomeRowStatus(
              row: 0,
              height: heroHeight,
              autofocus: _focus.atHero,
              title: '今日推荐',
              note: '正在加载推荐…',
              loading: true,
            );
          }
          if (tmdbOn) {
            return _HomeRowStatus(
              row: 0,
              height: heroHeight,
              autofocus: _focus.atHero,
              title: '今日推荐',
              note: '暂无今日推荐',
              onRetry: () => ref.invalidate(tmdbRowProvider(TmdbRow.trendingDay)),
            );
          }
          return _Welcome(hasServers: servers.isNotEmpty, tmdbOn: tmdbOn, autofocus: _focus.atHero, height: heroHeight);
        },
      ),
      if (showResume)
        (
          row: 1,
          height: extent(landscapeHeight),
          build: _cachedRow(1, (resumeAsync, resumeState, servers, landscapeHeight), (context) {
            if (resume.isEmpty) {
              if (_focus.rowAt(1) is RevealableFocusRow) _focus.preserveRow(1);
              return _HomeRowStatus(
                row: 1,
                title: '继续观看',
                note: resumeAsync.isLoading ? '正在加载…' : '暂时无法刷新继续观看',
                loading: resumeAsync.isLoading,
                landscape: true,
                onRetry: resumeAsync.isLoading
                    ? null
                    : () => ref.read(mediaFeedRefreshProvider.notifier).refresh(MediaFeedKind.resume),
              );
            }
            final keys = [for (final it in resume) '${it.serverId}/${it.id}'];
            final initial = _focus.updateItems(1, keys);
            return FocusRow(
              rowIndex: 1,
              title: (resumeState?.failures ?? 0) == 0 ? '继续观看' : '继续观看 · 部分记录暂未刷新',
              itemKeys: keys,
              initialIndex: initial,
              autoScrollVertical: false,
              forwardShiftWheelAtEdge: true,
              itemCount: resume.length,
              itemExtent: LandscapeCard.width,
              height: landscapeHeight,
              onItemFocused: (i) {
                if (!_focus.remember(1, i)) return;
                _setBackdrop(_itemBackdrop(resume[i], badge: '继续观看', server: serverNames[resume[i].serverId]));
                _preloadResume(resume[i]);
              },
              itemBuilder: (context, i, node) => _hoverTrack(
                mediaLandscapeCard(
                  context,
                  resume[i],
                  node,
                  watchedOn: serverNames[resume[i].serverId] ?? '未知服务器',
                  onMenu: () => openMediaItem(context, resume[i]),
                ),
              ),
            );
          }),
        ),
      if (recent.isNotEmpty)
        (
          row: 2,
          height: extent(posterHeight),
          build: _cachedRow(2, (recent, servers, posterHeight), (context) {
            final keys = [for (final g in recent) '${g.primary.serverId}/${g.primary.id}'];
            return FocusRow(
              rowIndex: 2,
              title: '最近入库',
              itemCount: recent.length,
              itemKeys: keys,
              initialIndex: _focus.updateItems(2, keys),
              autoScrollVertical: false,
              forwardShiftWheelAtEdge: true,
              itemExtent: PosterCard.width,
              height: posterHeight,
              onItemFocused: (i) {
                if (!_focus.remember(2, i)) return;
                _setBackdrop(
                  _itemBackdrop(recent[i].primary, badge: '最近入库', server: serverNames[recent[i].primary.serverId]),
                );
              },
              itemBuilder: (context, i, node) => _hoverTrack(mediaPosterCard(context, recent[i].primary, node)),
            );
          }),
        ),
      for (final (index, title, row) in [
        (3, '正在热映', TmdbRow.nowPlaying),
        (4, '正在播出', TmdbRow.onTheAir),
        (5, '本周趋势', TmdbRow.trendingWeek),
        (6, '今日动漫', TmdbRow.animeToday),
        (9, '高分剧集', TmdbRow.topRatedTv),
      ])
        (
          row: index,
          height: extent(posterHeight),
          build: _cachedRow(
            index,
            (tmdbOn, posterHeight),
            (context) => Consumer(
              builder: (context, rowRef, _) =>
                  _recommendation(context, rowRef, index, title, row, tmdbOn, posterHeight),
            ),
          ),
        ),
      (
        row: 7,
        height: extent(peopleHeight),
        build: _cachedRow(
          7,
          (tmdbOn, peopleHeight),
          (context) => Consumer(
            builder: (context, rowRef, _) {
              if (!tmdbOn) return _unconfigured(7, '热门人物');
              final async = rowRef.watch(tmdbPeopleProvider);
              final people = async.value ?? const <TmdbPerson>[];
              if (people.isEmpty) {
                if (_focus.rowAt(7) is RevealableFocusRow) _focus.preserveRow(7);
                return _HomeRowStatus(
                  row: 7,
                  title: '热门人物',
                  note: async.hasError
                      ? '人物加载失败'
                      : async.isLoading
                      ? '正在加载…'
                      : '暂无人物推荐',
                  loading: async.isLoading,
                  circle: true,
                  onRetry: () => rowRef.invalidate(tmdbPeopleProvider),
                );
              }
              final keys = [for (final p in people) p.id];
              return FocusRow(
                rowIndex: 7,
                title: '热门人物',
                itemCount: people.length,
                itemKeys: keys,
                initialIndex: _focus.updateItems(7, keys),
                autoScrollVertical: false,
                forwardShiftWheelAtEdge: true,
                itemExtent: PersonCard.size,
                gap: 40,
                height: peopleHeight,
                onItemFocused: (i) => _focus.remember(7, i),
                itemBuilder: (context, i, node) => TmdbPersonCard(person: people[i], node: node),
              );
            },
          ),
        ),
      ),
      if (tmdbOn)
        (
          row: 8,
          height: extent(BrandCard.height),
          build: _cachedRow(8, BrandCard.height, (context) {
            final keys = [for (final n in tmdbNetworks) n.id];
            return FocusRow(
              rowIndex: 8,
              title: '播出平台',
              itemCount: tmdbNetworks.length,
              itemKeys: keys,
              initialIndex: _focus.updateItems(8, keys),
              autoScrollVertical: false,
              forwardShiftWheelAtEdge: true,
              itemExtent: BrandCard.width,
              height: BrandCard.height,
              onItemFocused: (i) => _focus.remember(8, i),
              itemBuilder: (context, i, node) {
                final n = tmdbNetworks[i];
                return BrandCard(
                  node: node,
                  art: placeholderArt(n.name),
                  name: n.name,
                  backgroundColor: BrandCard.logoBackground,
                  logo: TmdbImage(
                    path: n.logoPath,
                    kind: TmdbImageKind.logo,
                    width: 190,
                    fit: BoxFit.contain,
                    transparentFallback: true,
                    fallback: Center(
                      child: Text(
                        n.name,
                        style: const TextStyle(color: Color(0xFF121218), fontSize: 28, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  onActivate: () => context.push('/tmdb/network/${n.id}?name=${Uri.encodeComponent(n.name)}'),
                );
              },
            );
          }),
        ),
    ]..sort((a, b) => a.row.compareTo(b.row));
    _focus.order = [for (final section in sections) section.row];
    _offsets.clear();
    _extents.clear();
    var offset = 0.0;
    for (final section in sections) {
      _offsets[section.row] = offset;
      _extents[section.row] = section.height;
      offset += section.height;
    }
    _schedulePrefetch();
    return FocusScope(
      node: _anchor,
      child: RowFocusScope(
        controller: _focus,
        child: BackHandler(
          onBack: _onBack,
          child: Listener(
            onPointerDown: (_) => _focus.cancelNavigation(),
            onPointerHover: (_) => _focus.cancelNavigation(),
            onPointerSignal: (_) {
              InputMode.markPointer();
              _focus.cancelNavigation();
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: PageBackdrop(
                    art: backdrop?.art ?? const ArtSpec(Color(0xFF1A2233), Color(0xFF07080B), Color(0xFF3A4766)),
                    image: backdrop?.image,
                    imageKey: backdrop?.key,
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: ListenableBuilder(
                      listenable: _scroll,
                      builder: (context, _) => ColoredBox(
                        color: VColors.background.withValues(
                          alpha: ((_scroll.hasClients ? _scroll.offset : 0.0) / 500).clamp(0.0, 1.0) * 0.45,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.only(bottom: 40),
                    scrollCacheExtent: ScrollCacheExtent.pixels(_mountExtent),
                    itemCount: sections.length + 1,
                    itemExtentBuilder: (i, _) =>
                        i == sections.length ? math.max(112.0, 72 + textScale.scale(20) * 1.5) : sections[i].height,
                    findChildIndexCallback: (key) {
                      if (key == const ValueKey('home-end')) return sections.length;
                      final i = sections.indexWhere((s) => key == ValueKey(s.row));
                      return i < 0 ? null : i;
                    },
                    itemBuilder: (context, i) {
                      if (i == sections.length) return const EndOfPage(key: ValueKey('home-end'));
                      final section = sections[i];
                      return HomeFocusSlot(
                        key: ValueKey(section.row),
                        row: section.row,
                        controller: _focus,
                        child: ListenableBuilder(
                          listenable: _scroll,
                          child: Align(alignment: Alignment.topLeft, child: section.build(context)),
                          builder: (context, child) {
                            final top = _scroll.hasClients ? _scroll.offset : 0.0;
                            final viewport = _scroll.hasClients
                                ? _scroll.position.viewportDimension
                                : MediaQuery.sizeOf(context).height;
                            return TickerMode(
                              enabled:
                                  _offsets[section.row]! < top + viewport &&
                                  _offsets[section.row]! + section.height > top,
                              child: child!,
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _unconfigured(int row, String title) => _HomeRowStatus(
    row: row,
    title: title,
    note: '配置 TMDB 后显示（设置 → 接口与网络）',
    actionLabel: '设置 TMDB',
    onRetry: () => context.go('/settings'),
  );

  Widget _recommendation(
    BuildContext context,
    WidgetRef rowRef,
    int index,
    String title,
    TmdbRow row,
    bool enabled,
    double height,
  ) {
    if (!enabled) return _unconfigured(index, title);
    final async = rowRef.watch(tmdbRowProvider(row));
    final items = async.value ?? const <TmdbTitle>[];
    if (items.isEmpty) {
      if (_focus.rowAt(index) is RevealableFocusRow) _focus.preserveRow(index);
      return _HomeRowStatus(
        row: index,
        title: title,
        note: async.hasError
            ? '推荐加载失败'
            : async.isLoading
            ? '正在加载…'
            : '暂无推荐内容',
        loading: async.isLoading,
        onRetry: () => rowRef.invalidate(tmdbRowProvider(row)),
      );
    }
    final keys = [for (final item in items) item.key];
    return FocusRow(
      rowIndex: index,
      title: async.hasError ? '$title · 暂未刷新' : title,
      itemCount: items.length,
      itemKeys: keys,
      initialIndex: _focus.updateItems(index, keys),
      autoScrollVertical: false,
      forwardShiftWheelAtEdge: true,
      itemExtent: PosterCard.width,
      height: height,
      onItemFocused: (i) {
        if (!_focus.remember(index, i)) return;
        _setBackdrop(_tmdbBackdrop(items[i], badge: title));
      },
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
    final detail = ref.watch(tmdbTitleProvider((isTv: title.isTv, id: title.id)));
    final logo = detail.value?.logoPath;
    // 与详情页一致：固定字号（短标题 100、长标题 72），最多两行
    final text = Text(
      title.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: DefaultTextStyle.of(context).style,
    );
    // 还不知道有没有 Logo 时留空（不先显示文字再换成 Logo，电视上看起来像闪了一下）
    if (detail.isLoading && !detail.hasValue) return const SizedBox(height: 150);
    if (logo == null) return text;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620, maxHeight: 150),
      child: TmdbImage(
        path: logo,
        kind: TmdbImageKind.logo,
        width: 620,
        fit: BoxFit.contain,
        alignment: Alignment.bottomLeft,
        transparentFallback: true,
        errorFallback: text,
      ),
    );
  }
}

/// 首次使用 / 未配置：占据 Hero 区，结构和正常首页一致（右上角状态栏、左侧说明与按钮）
class _Welcome extends StatelessWidget {
  const _Welcome({required this.hasServers, required this.tmdbOn, this.autofocus = true, this.height});

  final bool hasServers;
  final bool tmdbOn;
  final bool autofocus;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height ?? HomeHero.heightOf(context),
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
                        autofocus: autofocus,
                        large: true,
                        icon: Icons.add_rounded,
                        label: '添加服务器',
                        onPressed: () => context.go('/library/add'),
                      ),
                    if (!tmdbOn)
                      (node) => PillButton(
                        focusNode: node,
                        autofocus: autofocus && hasServers,
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

/// 分区状态保留原行的几何尺寸，并提供一个可导航的焦点锚点。
class _HomeRowStatus extends StatelessWidget {
  const _HomeRowStatus({
    required this.row,
    required this.title,
    required this.note,
    this.loading = false,
    this.landscape = false,
    this.circle = false,
    this.onRetry,
    this.actionLabel = '重试',
    this.autofocus = false,
    this.height,
  });
  final int row;
  final String title;
  final String note;
  final bool loading;
  final bool landscape;
  final bool circle;
  final VoidCallback? onRetry;
  final String actionLabel;
  final bool autofocus;
  final double? height;

  /// 加载中：焦点锚点就是第一张骨架卡片（Hero 是播放按钮的骨架），不再在骨架上叠一个「正在加载…」按钮
  Widget _anchor(Widget block, double radius) => FocusButtonRow(
    rowIndex: row,
    autoScroll: false,
    children: [
      (node) => VFocusable(
        focusNode: node,
        autofocus: autofocus,
        radius: radius,
        semanticLabel: note,
        builder: (context, _) => block,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      if (loading)
        Positioned.fill(
          child: row == 0
              ? _HeroSkeleton(height: height, wrapButton: (b) => _anchor(b, 34))
              : _SkeletonRow(
                  title: title,
                  landscape: landscape,
                  circle: circle,
                  animate: !PlatformProfile.isTv && !VMotion.reduced(context),
                  wrapFirst: (b) => _anchor(b, circle ? 999 : VRadius.card),
                ),
        )
      else
        Positioned(
          left: VSpace.contentLeft,
          right: VSpace.safeH,
          top: 12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: VText.rowTitle),
              const SizedBox(height: 20),
              Text(note, style: VText.label.copyWith(color: VColors.textSecondary)),
            ],
          ),
        ),
      if (!loading)
        Positioned(
          left: VSpace.contentLeft,
          top: row == 0 ? null : 120,
          bottom: row == 0 ? HomeHero.buttonsBottom : null,
          child: FocusButtonRow(
            rowIndex: row,
            autoScroll: false,
            children: [
              (node) => PillButton(
                focusNode: node,
                autofocus: autofocus,
                label: loading
                    ? note
                    : onRetry == null
                    ? '暂无内容'
                    : actionLabel,
                icon: loading ? null : Icons.refresh_rounded,
                onPressed: loading ? null : onRetry,
              ),
            ],
          ),
        ),
    ],
  );
}

/// 加载中的 Hero 占位：和真实 Hero 同样的位置与尺寸
class _HeroSkeleton extends StatelessWidget {
  const _HeroSkeleton({this.height, this.wrapButton});
  final double? height;

  /// 把播放按钮的骨架包成焦点锚点（加载中遥控器也有落点）
  final Widget Function(Widget block)? wrapButton;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height ?? HomeHero.heightOf(context),
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
                  const SizedBox(height: 24),
                  _block(560, 84),
                  const SizedBox(height: 24),
                  _block(360, 26),
                  const SizedBox(height: 20),
                  _block(780, 24),
                  const SizedBox(height: 14),
                  _block(620, 24),
                  const SizedBox(height: 32),
                  Row(
                    children: [
                      wrapButton?.call(_block(220, 68, radius: 34)) ?? _block(220, 68, radius: 34),
                      const SizedBox(width: 40),
                      _block(170, 60, radius: 30),
                    ],
                  ),
                ],
              ),
            ),
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
    this.landscape = false,
    this.circle = false,
    this.animate = true,
    this.wrapFirst,
  });

  final String title;

  /// 第一张卡片包成焦点锚点
  final Widget Function(Widget block)? wrapFirst;
  final bool landscape;
  final bool circle;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final w = circle ? PersonCard.size : (landscape ? LandscapeCard.width : PosterCard.width);
    final h = circle ? PersonCard.size : (landscape ? LandscapeCard.imageHeight : PosterCard.imageHeight);
    final count =
        ((MediaQuery.sizeOf(context).width - VSpace.contentLeft) / (w + (circle ? 40 : VSpace.rowGap))).ceil() + 1;
    final cards = Row(
      children: [
        for (var i = 0; i < count; i++) ...[
          Column(
            crossAxisAlignment: circle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              if (i == 0 && wrapFirst != null)
                wrapFirst!(_block(w, h, radius: circle ? w / 2 : VRadius.card))
              else
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
              Text('加载中…', style: VText.caption.copyWith(color: VColors.textTertiary)),
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
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (PlatformProfile.isTv || VMotion.reduced(context)) {
      _c.stop();
      _c.value = 0.6;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

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
