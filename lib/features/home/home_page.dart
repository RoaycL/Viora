import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/input/back_handler.dart';
import '../../app/theme.dart';
import '../../ui/focus/row_focus.dart';
import '../../ui/panels/context_menu.dart';
import '../../ui/rows/cards.dart';
import '../../ui/rows/focus_row.dart';
import '../../ui/widgets/art.dart';
import '../../ui/widgets/backdrop.dart';
import '../../ui/widgets/toast.dart';
import 'home_hero.dart';
import 'home_mock.dart';

/// 首页（docs/06-ui-design.md §4）：Hero + 推荐行，背景跟随焦点。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => const RowFocusScope(child: _HomeBody());
}

class _HomeBody extends StatefulWidget {
  const _HomeBody();

  @override
  State<_HomeBody> createState() => _HomeBodyState();
}

class _HomeBodyState extends State<_HomeBody> {
  final _scroll = ScrollController();
  final _heroKey = GlobalKey<HomeHeroState>();
  int _heroIndex = 0;
  ArtSpec _backdrop = HomeMock.heroes.first.art;
  Timer? _backdropDebounce;

  late final _nowShowing = HomeMock.posters('now', 12);
  late final _onAir = HomeMock.posters('air', 12);
  late final _trending = HomeMock.posters('trend', 12);
  late final _anime = HomeMock.posters('anime', 12);
  late final _topRated = HomeMock.posters('top', 12);

  @override
  void dispose() {
    _backdropDebounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// 背景切换加防抖，避免快速移动 / 鼠标划过时背景频繁闪烁。
  void _setBackdrop(ArtSpec art) {
    _backdropDebounce?.cancel();
    _backdropDebounce = Timer(const Duration(milliseconds: 220), () {
      if (mounted && art != _backdrop) setState(() => _backdrop = art);
    });
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

  void _openDetail(MockTitle t) => context.push('/detail/${t.id}');

  void _openMenu(MockTitle t, {bool resume = false}) {
    showContextMenu(
      context,
      title: t.title,
      actions: [
        MenuAction('去详情', Icons.info_outline_rounded, () => _openDetail(t)),
        MenuAction('选择资源播放', Icons.swap_horiz_rounded, () => showToast('资源选择将在 M3 接入')),
        MenuAction('标记已看', Icons.check_rounded, () => showToast('已标记为已看')),
        MenuAction('加入收藏', Icons.favorite_border_rounded, () => showToast('已加入收藏')),
        if (resume) MenuAction('从继续观看中移除', Icons.close_rounded, () => showToast('已移除')),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return BackHandler(
      onBack: _onBack,
      child: Stack(
        children: [
          Positioned.fill(child: PageBackdrop(art: _backdrop)),
          Positioned.fill(
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.only(bottom: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  HomeHero(
                    key: _heroKey,
                    rowIndex: 0,
                    items: HomeMock.heroes,
                    index: _heroIndex,
                    onIndexChanged: (i) {
                      setState(() => _heroIndex = i);
                      _setBackdrop(HomeMock.heroes[i].art);
                    },
                    onFocused: () {
                      _setBackdrop(HomeMock.heroes[_heroIndex].art);
                      _scroll.animateTo(0, duration: VMotion.scroll, curve: Curves.easeOutCubic);
                    },
                    onPlay: (t) => showToast('播放「${t.title}」将在 M1 接入播放器'),
                    onDetail: _openDetail,
                  ),
                  FocusRow(
                    rowIndex: 1,
                    title: '继续观看',
                    itemCount: HomeMock.resume.length,
                    itemExtent: LandscapeCard.width,
                    height: LandscapeCard.height,
                    onItemFocused: (i) => _setBackdrop(HomeMock.resume[i].art),
                    itemBuilder: (context, i, node) {
                      final t = HomeMock.resume[i];
                      return LandscapeCard(
                        node: node,
                        art: t.art,
                        title: t.title,
                        subtitle: t.subtitle,
                        tag: t.server,
                        caption: t.remaining,
                        progress: t.progress,
                        onActivate: () => showToast('继续播放「${t.title}」将在 M1 接入播放器'),
                        onMenu: () => _openMenu(t, resume: true),
                      );
                    },
                  ),
                  _posterRow(2, '正在热映', _nowShowing),
                  _posterRow(3, '正在播出', _onAir),
                  _posterRow(4, '本周趋势', _trending),
                  _posterRow(5, '今日动漫', _anime),
                  FocusRow(
                    rowIndex: 6,
                    title: '热门人物',
                    itemCount: HomeMock.people.length,
                    itemExtent: PersonCard.size,
                    gap: 40,
                    height: PersonCard.height,
                    onItemFocused: (i) => _setBackdrop(HomeMock.people[i].art),
                    itemBuilder: (context, i, node) {
                      final p = HomeMock.people[i];
                      return PersonCard(node: node, art: p.art, name: p.name, role: p.role);
                    },
                  ),
                  FocusRow(
                    rowIndex: 7,
                    title: '播出平台',
                    itemCount: HomeMock.platforms.length,
                    itemExtent: BrandCard.width,
                    height: BrandCard.height,
                    onItemFocused: (i) => _setBackdrop(HomeMock.platforms[i].art),
                    itemBuilder: (context, i, node) {
                      final b = HomeMock.platforms[i];
                      return BrandCard(node: node, art: b.art, name: b.name);
                    },
                  ),
                  _posterRow(8, '高分剧集', _topRated),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _posterRow(int rowIndex, String title, List<MockTitle> items) {
    return FocusRow(
      rowIndex: rowIndex,
      title: title,
      itemCount: items.length,
      itemExtent: PosterCard.width,
      height: PosterCard.height,
      onItemFocused: (i) => _setBackdrop(items[i].art),
      itemBuilder: (context, i, node) {
        final t = items[i];
        return PosterCard(
          node: node,
          art: t.art,
          title: t.title,
          subtitle: '${t.year} · ★ ${t.rating!.toStringAsFixed(1)}',
          resources: t.resources,
          onActivate: () => _openDetail(t),
          onMenu: () => _openMenu(t),
        );
      },
    );
  }
}
