import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/input/intents.dart';
import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../../ui/focus/input_mode.dart';
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
    this.autoRotate = true,
  });

  /// 显示轮播指示点（显示推荐行焦点的预览时隐藏）
  final bool showDots;

  /// 是否自动轮播（正在预览推荐行作品、Hero 已滚出视野时为 false）
  final bool autoRotate;

  /// 无操作多久后自动切到下一部
  static const rotateEvery = Duration(seconds: 3);

  /// Hero 高度：占屏幕约 72%（封面背景更大，下面的行往下移）
  static double heightOf(BuildContext context) => (MediaQuery.sizeOf(context).height * 0.72).clamp(660.0, 1200.0);

  /// 按钮行距 Hero 底部的距离（按钮位置固定，不随标题、简介长短上下移动）
  static const buttonsBottom = 96.0;

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

  DateTime _lastSwitch = DateTime.now();

  @override
  void initState() {
    super.initState();
    // 每秒检查一次：无操作满 3 秒、且距上次切换满 3 秒时切到下一部
    _rotate = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !widget.autoRotate || widget.items.length < 2) return;
      // Hero 已经滚出视野（在看下面的行）时不轮播
      final pos = Scrollable.maybeOf(context)?.position;
      if (pos != null && pos.hasPixels && pos.pixels > HomeHero.heightOf(context) / 2) return;
      final now = DateTime.now();
      if (InputMode.idle < HomeHero.rotateEvery || now.difference(_lastSwitch) < HomeHero.rotateEvery) return;
      _switchTo(widget.index + 1);
    });
  }

  @override
  void didUpdateWidget(HomeHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) _lastSwitch = DateTime.now();
  }

  void _switchTo(int i) {
    if (widget.items.length < 2) return;
    _lastSwitch = DateTime.now();
    widget.onIndexChanged(i % widget.items.length);
  }

  void _onFocusChanged(int i, FocusNode node) {
    if (node.hasPrimaryFocus) {
      _remembered = i;
      widget.onFocused();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.items[widget.index.clamp(0, widget.items.length - 1)];
    final hasPlay = t.onPlay != null;
    // Windows：点封面大图进详情，不放「详情 / 查看详情」按钮（只保留播放）；
    // 电视：遥控器需要能聚焦的按钮，保留「播放 + 详情」或「查看详情」
    final desktop = PlatformProfile.isDesktop;
    final showButtons = !desktop || hasPlay;
    const buttonsHeight = 76.0;
    final hero = SizedBox(
      height: HomeHero.heightOf(context),
      child: Stack(
        children: [
          // 标题、简介：底部对齐在按钮上方，内容长短只影响向上延伸，不推动按钮
          Positioned(
            left: VSpace.contentLeft,
            bottom: showButtons ? HomeHero.buttonsBottom + buttonsHeight + 34 : HomeHero.buttonsBottom + 20,
            width: 900,
            child: AnimatedSwitcher(
              duration: VMotion.backdrop,
              layoutBuilder: (current, previous) =>
                  Stack(alignment: Alignment.bottomLeft, children: [...previous, ?current]),
              child: _HeroInfo(key: ValueKey(t.key), title: t),
            ),
          ),
          if (showButtons)
            Positioned(
              left: VSpace.contentLeft,
              bottom: HomeHero.buttonsBottom,
              height: buttonsHeight,
              child: Row(
                children: [
                  PillButton(
                    focusNode: _nodes[0],
                    autofocus: true,
                    large: true,
                    icon: hasPlay ? Icons.play_arrow_rounded : Icons.info_outline_rounded,
                    label: hasPlay ? '播放' : '查看详情',
                    onPressed: hasPlay ? t.onPlay : t.onDetail,
                  ),
                  // 电视上 TMDB 推荐只有「查看详情」（资源在详情页里搜索）；Windows 点封面进详情
                  if (hasPlay && !desktop) ...[
                    const SizedBox(width: 40),
                    PillButton(
                      focusNode: _nodes[1],
                      icon: Icons.info_outline_rounded,
                      label: '详情',
                      onPressed: t.onDetail,
                    ),
                  ],
                ],
              ),
            ),
          // 状态栏随 Hero 一起滚走，不遮挡下方内容
          const Positioned(right: VSpace.safeH, top: VSpace.safeV, child: StatusBar()),
          if (widget.showDots && widget.items.length > 1)
            Positioned(
              right: VSpace.safeH,
              bottom: HomeHero.buttonsBottom + 30,
              child: Row(
                children: [
                  for (var i = 0; i < widget.items.length; i++)
                    GestureDetector(
                      onTap: () => _switchTo(i),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 10),
                          child: AnimatedContainer(
                            duration: VMotion.scroll,
                            width: i == widget.index ? 36 : 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: i == widget.index ? Colors.white : const Color(0x59FFFFFF),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
    // 点击封面（标题、简介、背景）进详情；按住左右拖动切换上一部 / 下一部
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: desktop ? t.onDetail : null,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v < -150) _switchTo(widget.index + 1);
        if (v > 150) _switchTo(widget.index - 1 + widget.items.length);
      },
      child: MouseRegion(
        cursor: desktop ? SystemMouseCursors.click : MouseCursor.defer,
        child: showButtons
            ? hero
            // Windows 没有按钮时：封面本身作为第 0 行的焦点（键盘回车进详情）
            : Focus(
                focusNode: _nodes[0],
                autofocus: true,
                onKeyEvent: (node, e) {
                  if (e is KeyDownEvent && confirmKeys.contains(e.logicalKey)) {
                    t.onDetail();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: hero,
              ),
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
    final titleText = Text(
      t.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: VText.titleFor(t.title).copyWith(
        shadows: const [Shadow(color: Color(0x73000000), blurRadius: 40, offset: Offset(0, 6))],
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
              decoration: BoxDecoration(
                color: const Color(0x24FFFFFF),
                borderRadius: BorderRadius.circular(VRadius.xs),
              ),
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
        // 标题区不固定高度（向上延伸，两行长标题也完整显示）；Logo 图最高 150
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 160, minHeight: 100),
          child: Align(alignment: Alignment.bottomLeft, widthFactor: 1, heightFactor: 1, child: t.logo ?? titleText),
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
