import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;

import '../../app/platform_profile.dart';
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
/// 操作区持有焦点或鼠标停留时保持当前作品；离开后重新计时。
class HomeHero extends StatefulWidget {
  const HomeHero({
    super.key,
    required this.rowIndex,
    required this.items,
    required this.index,
    required this.onIndexChanged,
    required this.onFocused,
    required this.rotationPaused,
    required this.onToggleRotation,
    this.pendingIndex,
    this.height,
    this.showCarousel = true,
    this.autoRotate = true,
    this.isReady,
    this.autofocus = true,
  });

  /// 第 i 部是否已经准备好（图片已下载解码）；没准备好时轮播先等着，不切过去
  final bool Function(int index)? isReady;
  final bool autofocus;
  final bool rotationPaused;
  final VoidCallback onToggleRotation;
  final int? pendingIndex;
  final double? height;

  /// 显示轮播控件（显示推荐行焦点的预览时隐藏）
  final bool showCarousel;

  /// 是否自动轮播（正在预览推荐行作品、Hero 已滚出视野时为 false）
  final bool autoRotate;

  static const rotateEvery = Duration(seconds: 8);

  /// 有续播时为整行留空间；大字/较矮窗口优先保证 Hero 可读，允许内容继续向下滚动。
  static double heightOf(BuildContext context, {double reserveBelow = 0}) {
    final viewport = MediaQuery.sizeOf(context).height;
    final minimum = 600.0 + MediaQuery.textScalerOf(context).scale(280) - 280;
    final preferred = (viewport * 0.68).clamp(minimum, math.max(minimum, 1100.0)).toDouble();
    return reserveBelow > 0 ? math.min(preferred, math.max(minimum, viewport - reserveBelow)) : preferred;
  }

  /// 按钮行距 Hero 底部的距离（按钮位置固定，不随标题、简介长短上下移动）
  static const buttonsBottom = 56.0;

  final int rowIndex;
  final List<HeroEntry> items;
  final int index;
  final ValueChanged<int> onIndexChanged;
  final VoidCallback onFocused;

  @override
  State<HomeHero> createState() => HomeHeroState();
}

class HomeHeroState extends State<HomeHero> with WidgetsBindingObserver implements FocusRowHandle {
  /// 每个按钮固定一个节点（主按钮、详情、上一部、暂停、下一部）。按位置分配时，轮播切到有 / 没有「播放」的作品，
  /// 上一部 / 暂停 / 下一部会整体错一个节点，焦点跳到旁边的按钮或丢失
  static const _main = 0, _detail = 1, _prev = 2, _pause = 3, _next = 4;
  static const _labels = ['hero#0', 'hero#detail', 'hero#prev', 'hero#pause', 'hero#next'];
  late final List<FocusNode> _nodes = List.generate(5, (slot) {
    final node = FocusNode(debugLabel: _labels[slot]);
    node.addListener(() => _onFocusChanged(slot, node));
    return node;
  });
  RowFocusController? _controller;
  int _remembered = 0;
  Timer? _rotate;
  ValueListenable<TickerModeData>? _tickerMode;
  bool _hovered = false;
  bool _dragging = false;
  bool _appActive = true;

  bool get hasFocus => _nodes.any((n) => n.hasFocus);

  int get _actions => !PlatformProfile.isDesktop && _entry.onPlay != null ? 2 : 1;
  bool get _carousel => widget.showCarousel && widget.items.length > 1;
  HeroEntry get _entry => widget.items[widget.index.clamp(0, widget.items.length - 1)];
  int get _navigationIndex => widget.pendingIndex ?? widget.index;

  @override
  int get length => _actions + (_carousel ? 3 : 0);

  @override
  FocusNode nodeAt(int index) => _nodes[index < _actions ? index : index - _actions + _prev];

  int _indexOf(int slot) => slot < _prev ? slot : slot - _prev + _actions;

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
    final mode = TickerMode.getValuesNotifier(context);
    if (!identical(mode, _tickerMode)) {
      _tickerMode?.removeListener(_armRotation);
      _tickerMode = mode..addListener(_armRotation);
    }
    _armRotation();
  }

  @override
  void dispose() {
    _rotate?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _tickerMode?.removeListener(_armRotation);
    _controller?.unregister(widget.rowIndex, this);
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  bool get _canRotate =>
      mounted &&
      _appActive &&
      widget.autoRotate &&
      _carousel &&
      !widget.rotationPaused &&
      widget.pendingIndex == null &&
      !hasFocus &&
      !_hovered &&
      !_dragging &&
      _tickerMode?.value.enabled != false &&
      !VMotion.reduced(context);

  void _armRotation() {
    _rotate?.cancel();
    if (!_canRotate) return;
    _rotate = Timer(HomeHero.rotateEvery, () {
      if (!_canRotate) return;
      final next = (widget.index + 1) % widget.items.length;
      if (widget.isReady?.call(next) != false) _switchTo(next);
      _armRotation();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _armRotation();
  }

  @override
  void didUpdateWidget(HomeHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index ||
        oldWidget.autoRotate != widget.autoRotate ||
        oldWidget.rotationPaused != widget.rotationPaused ||
        oldWidget.pendingIndex != widget.pendingIndex ||
        oldWidget.items.length != widget.items.length) {
      _armRotation();
    }
    // 切到没有「播放」的作品时「详情」按钮消失：焦点留在主按钮（这时就是「查看详情」）
    if (_actions == 1 && _nodes[_detail].hasPrimaryFocus) _nodes[_main].requestFocus();
    final focused = _nodes.indexWhere((n) => n.hasPrimaryFocus);
    if (focused >= 0) _remembered = _indexOf(focused == _detail && _actions == 1 ? _main : focused);
  }

  void _switchTo(int i) {
    if (widget.items.length < 2) return;
    widget.onIndexChanged((i + widget.items.length) % widget.items.length);
    _armRotation();
  }

  void _onFocusChanged(int slot, FocusNode node) {
    if (node.hasPrimaryFocus) {
      _remembered = _indexOf(slot);
      widget.onFocused();
    }
    _armRotation();
  }

  @override
  Widget build(BuildContext context) {
    final t = _entry;
    final desktop = PlatformProfile.isDesktop;
    final compact = (widget.height ?? HomeHero.heightOf(context)) < 740;
    final infoWidth = math.min(900.0, MediaQuery.sizeOf(context).width - VSpace.contentLeft - VSpace.safeH);
    final reduced = VMotion.reduced(context);
    final hero = SizedBox(
      height: widget.height ?? HomeHero.heightOf(context),
      child: Stack(
        children: [
          Positioned(
            left: VSpace.contentLeft,
            bottom: HomeHero.buttonsBottom + 76 + 24,
            width: infoWidth,
            child: AnimatedSwitcher(
              duration: VMotion.duration(context, const Duration(milliseconds: 180)),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.bottomLeft,
                children: [
                  if (previous.isNotEmpty) ExcludeSemantics(key: previous.last.key, child: previous.last),
                  if (current != null) ExcludeSemantics(key: current.key, excluding: false, child: current),
                ],
              ),
              child: _HeroInfo(key: ValueKey(t.key), title: t, compact: compact),
            ),
          ),
          Positioned(
            left: VSpace.contentLeft,
            bottom: HomeHero.buttonsBottom,
            child: Row(
              children: [
                PillButton(
                  focusNode: _nodes[_main],
                  autofocus: widget.autofocus,
                  large: true,
                  icon: t.onPlay != null ? Icons.play_arrow_rounded : Icons.info_outline_rounded,
                  label: t.onPlay != null ? '播放' : '查看详情',
                  onPressed: t.onPlay ?? t.onDetail,
                ),
                if (_actions == 2) ...[
                  const SizedBox(width: 32),
                  PillButton(
                    focusNode: _nodes[_detail],
                    icon: Icons.info_outline_rounded,
                    label: '详情',
                    onPressed: t.onDetail,
                  ),
                ],
              ],
            ),
          ),
          // 电视的服务器状态和时钟在顶部标签栏右侧
          if (!PlatformProfile.isTv) const Positioned(right: VSpace.safeH, top: VSpace.safeV, child: StatusBar()),
          if (_carousel)
            Positioned(
              right: VSpace.safeH,
              bottom: HomeHero.buttonsBottom + 4,
              child: Row(
                children: [
                  Tooltip(
                    message: '上一部推荐',
                    excludeFromSemantics: true,
                    child: CircleIconButton(
                      focusNode: _nodes[_prev],
                      icon: Icons.chevron_left_rounded,
                      tooltip: '上一部推荐',
                      onPressed: () => _switchTo(_navigationIndex - 1),
                    ),
                  ),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 184,
                    child: Text(
                      widget.pendingIndex != null
                          ? '正在准备…'
                          : '${widget.index + 1} / ${widget.items.length}${widget.rotationPaused || reduced ? ' · 手动' : ''}',
                      textAlign: TextAlign.center,
                      style: VText.caption,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Tooltip(
                    message: reduced ? '系统已减少动画，自动轮播关闭' : (widget.rotationPaused ? '开启自动轮播' : '暂停自动轮播'),
                    excludeFromSemantics: true,
                    child: CircleIconButton(
                      focusNode: _nodes[_pause],
                      icon: widget.rotationPaused || reduced ? Icons.play_arrow_rounded : Icons.pause_rounded,
                      tooltip: reduced ? '系统已减少动画，自动轮播关闭' : (widget.rotationPaused ? '开启自动轮播' : '暂停自动轮播'),
                      onPressed: reduced ? null : widget.onToggleRotation,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Tooltip(
                    message: '下一部推荐',
                    excludeFromSemantics: true,
                    child: CircleIconButton(
                      focusNode: _nodes[_next],
                      icon: Icons.chevron_right_rounded,
                      tooltip: '下一部推荐',
                      onPressed: () => _switchTo(_navigationIndex + 1),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    return MouseRegion(
      onEnter: (_) {
        _hovered = true;
        _armRotation();
      },
      onExit: (_) {
        _hovered = false;
        _armRotation();
      },
      cursor: desktop ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: desktop ? t.onDetail : null,
        onHorizontalDragStart: (_) {
          _dragging = true;
          _armRotation();
        },
        onHorizontalDragCancel: () {
          _dragging = false;
          _armRotation();
        },
        onHorizontalDragEnd: (d) {
          _dragging = false;
          final velocity = d.primaryVelocity ?? 0;
          if (velocity < -150) _switchTo(_navigationIndex + 1);
          if (velocity > 150) _switchTo(_navigationIndex - 1);
          _armRotation();
        },
        child: hero,
      ),
    );
  }
}

class _HeroInfo extends StatelessWidget {
  const _HeroInfo({super.key, required this.title, this.compact = false});

  final HeroEntry title;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = title;
    final gap = compact ? 16.0 : 22.0;
    final scale = MediaQuery.textScalerOf(context);
    final titleStyle = DefaultTextStyle.of(context).style
        .merge(VText.titleFor(t.title))
        .copyWith(
          fontSize: compact ? (t.title.length > 8 ? 56 : 76) : null,
          shadows: const [Shadow(color: Color(0x73000000), blurRadius: 40, offset: Offset(0, 6))],
        );
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
    final titleText = Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: titleStyle);
    const dot = Text('  •  ', style: TextStyle(fontSize: 22, color: Color(0x66FFFFFF)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0x24FFFFFF),
                borderRadius: BorderRadius.circular(VRadius.xs),
              ),
              child: Text(t.badge, style: const TextStyle(fontSize: 20, letterSpacing: 1)),
            ),
            Text(
              [t.kindLabel, if (t.resources != null) t.resources! > 0 ? '${t.resources} 个资源' : '媒体库暂无'].join(' · '),
              style: const TextStyle(fontSize: 20, color: Color(0xB8FFFFFF), letterSpacing: 2),
            ),
          ],
        ),
        SizedBox(height: gap),
        // 标题区不固定高度（向上延伸，两行长标题也完整显示）；Logo 图最高 150
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 760,
            maxHeight: scale.scale(compact ? 112 : 160),
            minHeight: scale.scale(compact ? 76 : 100),
          ),
          child: DefaultTextStyle(
            style: titleStyle,
            child: Align(alignment: Alignment.bottomLeft, widthFactor: 1, heightFactor: 1, child: t.logo ?? titleText),
          ),
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
        SizedBox(height: gap),
        DefaultTextStyle.merge(
          style: const TextStyle(fontSize: 22, color: Color(0xD1FFFFFF)),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (var i = 0; i < meta.length; i++) ...[if (i > 0) dot, meta[i]],
            ],
          ),
        ),
        SizedBox(height: gap),
        SizedBox(
          width: 780,
          child: Text(
            t.overview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: VText.body.copyWith(fontSize: compact ? 22 : null, color: VColors.textSecondary),
          ),
        ),
      ],
    );
  }
}
