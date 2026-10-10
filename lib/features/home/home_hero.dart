import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../ui/focus/row_focus.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/status_bar.dart';
import '../../ui/widgets/art.dart';

/// Hero 的一条：TMDB 今日趋势，或（未配置 TMDB 时）媒体库最近入库
@immutable
class HeroEntry {
  const HeroEntry({
    required this.key,
    required this.title,
    required this.art,
    required this.badge,
    required this.kindLabel,
    required this.onDetail,
    this.latinTitle,
    this.logo,
    this.year,
    this.genres = const [],
    this.rating,
    this.overview = '',
    this.resources,
    this.onPlay,
    this.onSearch,
  });

  final String key;
  final String title;
  final String? latinTitle;
  final ArtSpec art;

  /// 标题 Logo；为空或加载不到时显示文字标题
  final Widget? logo;
  final String badge;
  final String kindLabel;
  final int? year;
  final List<String> genres;
  final double? rating;
  final String overview;

  /// 媒体库里的资源数；null = 不显示
  final int? resources;
  final VoidCallback? onPlay;
  final VoidCallback onDetail;
  final VoidCallback? onSearch;
}

/// 首页 Hero（效果图：首页 · 焦点在 Hero 播放按钮）。
///
/// 焦点在 Hero 按钮上且 8 秒无操作时自动轮播到下一部；按钮行作为第 0 行参与行导航。
class HomeHero extends StatefulWidget {
  const HomeHero({
    super.key,
    required this.rowIndex,
    required this.items,
    required this.index,
    required this.onIndexChanged,
    required this.onFocused,
    this.showDots = true,
  });

  /// 显示轮播指示点（显示推荐行焦点的预览时隐藏）
  final bool showDots;

  static const height = 660.0;
  static const rotateEvery = Duration(seconds: 8);

  final int rowIndex;
  final List<HeroEntry> items;
  final int index;
  final ValueChanged<int> onIndexChanged;
  final VoidCallback onFocused;

  @override
  State<HomeHero> createState() => HomeHeroState();
}

class HomeHeroState extends State<HomeHero> implements FocusRowHandle {
  late final List<FocusNode> _nodes = List.generate(2, (i) {
    final node = FocusNode(debugLabel: 'hero#$i');
    node.addListener(() => _onFocusChanged(i, node));
    return node;
  });
  RowFocusController? _controller;
  int _remembered = 0;
  Timer? _rotate;

  bool get hasFocus => _nodes.any((n) => n.hasFocus);

  @override
  int get length => _nodes.length;

  @override
  FocusNode nodeAt(int index) => _nodes[index];

  @override
  int get rememberedIndex => _remembered;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = RowFocusScope.of(context);
    if (!identical(controller, _controller)) {
      _controller?.unregister(widget.rowIndex, this);
      _controller = controller..register(widget.rowIndex, this);
    }
  }

  @override
  void dispose() {
    _rotate?.cancel();
    _controller?.unregister(widget.rowIndex, this);
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _onFocusChanged(int i, FocusNode node) {
    if (node.hasPrimaryFocus) {
      _remembered = i;
      widget.onFocused();
    }
    // 每次焦点变化都重置轮播计时；焦点离开 Hero 时停止。
    _rotate?.cancel();
    if (hasFocus) {
      _rotate = Timer.periodic(HomeHero.rotateEvery, (_) {
        if (widget.items.length > 1) widget.onIndexChanged((widget.index + 1) % widget.items.length);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.items[widget.index.clamp(0, widget.items.length - 1)];
    final hasPlay = t.onPlay != null;
    return SizedBox(
      height: HomeHero.height,
      child: Stack(
        children: [
          Positioned(
            left: VSpace.contentLeft,
            top: 118,
            width: 900,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedSwitcher(
                  duration: VMotion.backdrop,
                  layoutBuilder: (current, previous) =>
                      Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
                  child: _HeroInfo(key: ValueKey(t.key), title: t),
                ),
                const SizedBox(height: 34),
                Row(
                  children: [
                    PillButton(
                      focusNode: _nodes[0],
                      autofocus: true,
                      large: true,
                      icon: hasPlay ? Icons.play_arrow_rounded : Icons.info_outline_rounded,
                      label: hasPlay ? '播放' : '查看详情',
                      onPressed: hasPlay ? t.onPlay : t.onDetail,
                    ),
                    const SizedBox(width: 40),
                    PillButton(
                      focusNode: _nodes[1],
                      icon: hasPlay ? Icons.info_outline_rounded : Icons.search_rounded,
                      label: hasPlay ? '详情' : '搜索资源',
                      onPressed: hasPlay ? t.onDetail : t.onSearch,
                    ),
                  ],
                ),
              ],
            ),
          ),
          // 状态栏随 Hero 一起滚走，不遮挡下方内容
          const Positioned(right: VSpace.safeH, top: VSpace.safeV, child: StatusBar()),
          if (widget.showDots)
            Positioned(
              right: VSpace.safeH,
              top: 600,
              child: Row(
                children: [
                  for (var i = 0; i < widget.items.length; i++)
                    AnimatedContainer(
                      duration: VMotion.scroll,
                      margin: const EdgeInsets.only(left: 10),
                      width: i == widget.index ? 36 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == widget.index ? Colors.white : const Color(0x59FFFFFF),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HeroInfo extends StatelessWidget {
  const _HeroInfo({super.key, required this.title});

  final HeroEntry title;

  @override
  Widget build(BuildContext context) {
    final t = title;
    final meta = <Widget>[
      if (t.year != null) Text('${t.year}'),
      if (t.genres.isNotEmpty) Text(t.genres.take(3).join(' / ')),
      if (t.rating != null)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.star_rounded, size: 24, color: VColors.rating),
            const SizedBox(width: 4),
            Text(
              t.rating!.toStringAsFixed(1),
              style: const TextStyle(color: VColors.rating, fontWeight: FontWeight.w600),
            ),
          ],
        ),
    ];
    final titleText = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.bottomLeft,
      child: Text(
        t.title,
        maxLines: 1,
        style: VText.display.copyWith(
          shadows: const [Shadow(color: Color(0x73000000), blurRadius: 40, offset: Offset(0, 6))],
        ),
      ),
    );
    const dot = Text('  •  ', style: TextStyle(fontSize: 22, color: Color(0x66FFFFFF)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: const Color(0x24FFFFFF), borderRadius: BorderRadius.circular(8)),
              child: Text(t.badge, style: const TextStyle(fontSize: 20, letterSpacing: 1)),
            ),
            const SizedBox(width: 12),
            Text(
              [t.kindLabel, if (t.resources != null) t.resources! > 0 ? '${t.resources} 个资源' : '媒体库暂无'].join(' · '),
              style: const TextStyle(fontSize: 20, color: Color(0xB8FFFFFF), letterSpacing: 2),
            ),
          ],
        ),
        const SizedBox(height: 22),
        SizedBox(
          height: 150,
          width: 760,
          child: Align(alignment: Alignment.bottomLeft, child: t.logo ?? titleText),
        ),
        if (t.latinTitle != null && t.latinTitle != t.title)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 6),
            child: Text(
              t.latinTitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 22, letterSpacing: 4, color: Color(0xB8FFFFFF)),
            ),
          ),
        const SizedBox(height: 22),
        DefaultTextStyle.merge(
          style: const TextStyle(fontSize: 22, color: Color(0xD1FFFFFF)),
          child: Row(
            children: [
              for (var i = 0; i < meta.length; i++) ...[if (i > 0) dot, meta[i]],
            ],
          ),
        ),
        const SizedBox(height: 22),
        SizedBox(
          width: 780,
          child: Text(
            t.overview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: VText.body.copyWith(color: const Color(0xC7FFFFFF)),
          ),
        ),
      ],
    );
  }
}
