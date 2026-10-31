import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../../app/window_frame.dart';
import '../../data/aggregate/sources.dart';
import '../../data/config/app_config.dart';
import '../../data/config/config_store.dart';
import '../../data/media/media_models.dart';
import '../../domain/models/segment.dart';
import '../../player/engine.dart';
import '../../ui/widgets/brand_badges.dart';
import '../../ui/focus/focus_auto_scroll.dart';
import '../../ui/focus/focusable.dart';
import '../../ui/rows/cards.dart';
import '../../ui/widgets/server_image.dart';
import '../browse/media_cards.dart' show formatClock;
import '../library/library_page.dart' show ServerTypeLogo;

/// 播放控制层下方显示的面板（替换按钮行）
enum OsdPanel { none, sources, episodes }

/// 播放控制层（docs/08-player.md §4）：
/// 顶部 = 关闭、标题、时间与网速、弹幕 / 小窗 / 全屏（仅 Windows）/ 音轨 / 字幕 / 更多；
/// 底部 = 进度条，以及播放暂停、下一集、清晰度（切换资源）、选集、倍速。
class PlayerOsd extends StatelessWidget {
  const PlayerOsd({
    super.key,
    required this.state,
    required this.title,
    required this.source,
    required this.pendingSeek,
    required this.segments,
    required this.danmakuOn,
    required this.isEpisode,
    required this.hasNext,
    required this.panel,
    required this.playNode,
    this.seekNode,
    required this.onBack,
    required this.onPlayPause,
    required this.onNext,
    required this.onSeek,
    required this.onDanmaku,
    required this.onDanmakuMenu,
    required this.onAudio,
    required this.onSubtitle,
    required this.onMore,
    required this.onSources,
    required this.onEpisodes,
    required this.onRate,
    required this.onHoverControls,
    this.panelChild,
  });

  final EngineState state;
  final String title;
  final MediaSourceInfo? source;
  final Duration? pendingSeek;
  final List<Segment> segments;
  final bool danmakuOn;
  final bool isEpisode;
  final bool hasNext;
  final OsdPanel panel;
  final Widget? panelChild;

  /// 播放 / 暂停按钮的焦点（电视按 ↓ 时焦点落在这里）
  final FocusNode playNode;

  /// 电视：进度条的焦点（聚焦时 ←→ 快进快退）
  final FocusNode? seekNode;

  final VoidCallback onBack;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onDanmaku;
  final VoidCallback onDanmakuMenu;
  final VoidCallback onAudio;
  final VoidCallback onSubtitle;
  final VoidCallback onMore;
  final VoidCallback onSources;
  final VoidCallback onEpisodes;
  final VoidCallback onRate;

  /// 鼠标是否停在控制栏上（停着时不自动隐藏）
  final ValueChanged<bool> onHoverControls;

  @override
  Widget build(BuildContext context) {
    final desktop = PlatformProfile.isDesktop;
    final pos = pendingSeek ?? state.position;
    final dur = state.duration;
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.2, panel == OsdPanel.none ? 0.62 : 0.4, 1],
                colors: const [Color(0xB3000000), Color(0x00000000), Color(0x00000000), Color(0xE6000000)],
              ),
            ),
          ),
        ),
        // ───── 顶部 ─────
        Positioned(
          left: VSpace.safeH,
          right: VSpace.safeH,
          top: VSpace.safeV,
          child: MouseRegion(
            onEnter: (_) => onHoverControls(true),
            onExit: (_) => onHoverControls(false),
            child: Row(
              children: [
                // Windows 用鼠标点关闭；电视用遥控器返回键
                if (desktop) ...[
                  OsdIconButton(icon: Icons.close_rounded, label: '关闭', onPressed: onBack),
                  const SizedBox(width: 16),
                ],
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w600,
                      shadows: [Shadow(color: Color(0x99000000), blurRadius: 12)],
                    ),
                  ),
                ),
                const SizedBox(width: 24),
                _Status(speed: state.speed),
                const SizedBox(width: 24),
                OsdIconButton(
                  label: danmakuOn ? '弹幕：开' : '弹幕：关',
                  onPressed: onDanmaku,
                  onMenu: onDanmakuMenu,
                  child: (focused) => _DanmakuGlyph(on: danmakuOn, focused: focused),
                ),
                if (desktop) ...[
                  OsdIconButton(
                    icon: Icons.picture_in_picture_alt_rounded,
                    label: '小窗播放',
                    onPressed: MiniPlayerWindow.toggle,
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: windowFullScreen,
                    builder: (context, full, _) => OsdIconButton(
                      icon: full ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                      label: full ? '退出全屏' : '全屏',
                      onPressed: toggleFullScreen,
                    ),
                  ),
                ],
                OsdIconButton(icon: Icons.graphic_eq_rounded, label: '音轨', onPressed: onAudio),
                OsdIconButton(icon: Icons.subtitles_outlined, label: '字幕', onPressed: onSubtitle),
                OsdIconButton(icon: Icons.more_horiz_rounded, label: '更多', onPressed: onMore),
              ],
            ),
          ),
        ),
        // ───── 底部 ─────
        Positioned(
          left: VSpace.safeH,
          right: VSpace.safeH,
          bottom: VSpace.safeV - 12,
          child: MouseRegion(
            onEnter: (_) => onHoverControls(true),
            onExit: (_) => onHoverControls(false),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    SizedBox(width: 120, child: Text(formatClock(pos), style: _timeStyle)),
                    Expanded(
                      child: SeekBar(
                        position: pos,
                        duration: dur,
                        buffered: state.buffered,
                        segments: segments,
                        onSeek: desktop ? onSeek : null,
                        focusNode: desktop ? null : seekNode,
                        down: playNode,
                      ),
                    ),
                    SizedBox(
                      width: 120,
                      child: Text(formatClock(dur), textAlign: TextAlign.right, style: _timeStyle),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (panel != OsdPanel.none && panelChild != null)
                  panelChild!
                else
                  // ←→ 严格按顺序在按钮间移动：「下一集」和右边「分辨率」之间隔着大段空白，
                  // 按几何位置猜下一个按钮时电视上会过不去
                  OrderedButtonRow(
                    up: desktop ? null : seekNode,
                    children: [
                      OsdIconButton(
                        focusNode: playNode,
                        icon: state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        label: state.playing ? '暂停' : '播放',
                        size: 76,
                        iconSize: 50,
                        onPressed: onPlayPause,
                      ),
                      if (isEpisode)
                        OsdIconButton(
                          icon: Icons.skip_next_rounded,
                          label: '下一集',
                          iconSize: 40,
                          onPressed: hasNext ? onNext : null,
                        ),
                      const Spacer(),
                      if (source != null) OsdTextButton(label: _qualityLabel(source!), onPressed: onSources),
                      if (isEpisode) OsdTextButton(label: '选集', onPressed: onEpisodes),
                      OsdTextButton(label: state.rate == 1 ? '倍速' : '${_rate(state.rate)}x', onPressed: onRate),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static const _timeStyle = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static String _qualityLabel(MediaSourceInfo s) {
    final r = s.resolutionLabel;
    return r.isEmpty ? '资源' : r;
  }

  static String _rate(double r) => r == r.roundToDouble() ? r.toStringAsFixed(0) : '$r';
}

/// 下载速度，如 6.1 MB/s / 850 KB/s
String formatSpeed(int bytesPerSecond) {
  if (bytesPerSecond >= 1 << 20) return '${(bytesPerSecond / (1 << 20)).toStringAsFixed(1)} MB/s';
  return '${(bytesPerSecond / 1024).round()} KB/s';
}

/// 右上角：时间 · 网速
class _Status extends StatefulWidget {
  const _Status({required this.speed});

  final int? speed;

  @override
  State<_Status> createState() => _StatusState();
}

class _StatusState extends State<_Status> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = TimeOfDay.now();
    final clock = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return Text(
      [clock, if (widget.speed != null) formatSpeed(widget.speed!)].join('   '),
      style: const TextStyle(
        fontSize: 22,
        color: Color(0xD9FFFFFF),
        fontFeatures: [FontFeature.tabularFigures()],
        shadows: [Shadow(color: Color(0x99000000), blurRadius: 10)],
      ),
    );
  }
}

/// 圆形图标按钮：透明底，聚焦（电视）/ 悬停（Windows）时白底
class OsdIconButton extends StatelessWidget {
  const OsdIconButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.child,
    this.onMenu,
    this.focusNode,
    this.size = 64,
    this.iconSize = 32,
  });

  final IconData? icon;
  final Widget Function(bool focused)? child;
  final String label;
  final VoidCallback? onPressed;
  final VoidCallback? onMenu;
  final FocusNode? focusNode;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      excludeFromSemantics: true,
      message: PlatformProfile.isDesktop ? label : '',
      waitDuration: const Duration(milliseconds: 600),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: VFocusable(
          focusNode: focusNode,
          semanticLabel: label,
          radius: size / 2,
          scale: 1.06,
          showRing: false,
          onActivate: onPressed,
          onMenu: onMenu,
          builder: (context, focused) => AnimatedContainer(
            duration: VMotion.duration(context, VMotion.focus),
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: focused ? Colors.white : const Color(0x00FFFFFF)),
            child:
                child?.call(focused) ??
                Icon(
                  icon,
                  size: iconSize,
                  color: onPressed == null && onMenu == null
                      ? VColors.textTertiary
                      : (focused ? const Color(0xFF0B0C10) : Colors.white),
                  shadows: focused ? null : const [Shadow(color: Color(0x99000000), blurRadius: 10)],
                ),
          ),
        ),
      ),
    );
  }
}

/// 「弹」字图标；关闭时加一道斜线
class _DanmakuGlyph extends StatelessWidget {
  const _DanmakuGlyph({required this.on, required this.focused});

  final bool on;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final color = focused ? const Color(0xFF0B0C10) : Colors.white;
    return SizedBox(
      width: 36,
      height: 36,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 2.4),
            ),
            alignment: Alignment.center,
            child: Text(
              '弹',
              style: TextStyle(fontSize: 18, height: 1, fontWeight: FontWeight.w700, color: color),
            ),
          ),
          if (!on)
            Transform.rotate(
              angle: -0.785,
              child: Container(
                width: 44,
                height: 3,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(color: focused ? Colors.white : const Color(0xFF0B0C10), width: 0.6),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 文字按钮（4K / 选集 / 倍速）
class OsdTextButton extends StatelessWidget {
  const OsdTextButton({super.key, required this.label, required this.onPressed, this.selected});

  final String label;
  final VoidCallback? onPressed;

  /// 选中态（面板里的分组标签）
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: VFocusable(
        semanticLabel: label,
        selected: selected,
        radius: VRadius.sm,
        scale: 1.04,
        showRing: false,
        onActivate: onPressed,
        builder: (context, focused) => AnimatedContainer(
          duration: VMotion.duration(context, VMotion.focus),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          decoration: BoxDecoration(
            color: focused ? Colors.white : (selected == true ? const Color(0x33FFFFFF) : const Color(0x00FFFFFF)),
            borderRadius: BorderRadius.circular(VRadius.sm),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w600,
              color: focused ? const Color(0xFF0B0C10) : Colors.white,
              shadows: focused ? null : const [Shadow(color: Color(0x99000000), blurRadius: 10)],
            ),
          ),
        ),
      ),
    );
  }
}

/// 进度条：已播放、已缓冲、片头片尾标记；Windows 可以点击 / 拖动跳转，悬停显示时间
class SeekBar extends StatefulWidget {
  const SeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.buffered,
    this.segments = const [],
    this.onSeek,
    this.focusNode,
    this.down,
  });

  /// 电视：进度条可以拿焦点，聚焦时变粗，←→ 快进快退由播放页处理
  final FocusNode? focusNode;

  /// 电视：进度条上按 ↓ 去的按钮（播放 / 暂停）
  final FocusNode? down;

  final Duration position;
  final Duration duration;
  final Duration buffered;
  final List<Segment> segments;

  /// null = 不响应鼠标（电视用 ←→ 快进快退）
  final ValueChanged<Duration>? onSeek;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _hover;
  double? _drag;

  double _fraction(double dx, double width) => (dx / width).clamp(0.0, 1.0);

  Duration _at(double f) => Duration(milliseconds: (widget.duration.inMilliseconds * f).round());

  @override
  Widget build(BuildContext context) {
    final total = widget.duration.inMilliseconds;
    double frac(Duration d) => total <= 0 ? 0 : (d.inMilliseconds / total).clamp(0.0, 1.0);
    final interactive = widget.onSeek != null && total > 0;
    return LayoutBuilder(
      builder: (context, c) {
        final width = c.maxWidth;
        final focused = widget.focusNode?.hasFocus ?? false;
        final active = _drag != null || _hover != null || focused;
        final bar = CustomPaint(
          size: Size(width, 44),
          painter: _SeekPainter(
            played: _drag ?? frac(widget.position),
            buffered: frac(widget.buffered),
            marks: [
              for (final s in widget.segments) ...[frac(s.start), frac(s.end)],
            ],
            thick: active,
          ),
        );
        final node = widget.focusNode;
        if (node != null) {
          final down = widget.down;
          return Actions(
            actions: <Type, Action<Intent>>{
              if (down != null) DirectionalFocusIntent: _JumpAction(TraversalDirection.down, down),
            },
            child: Focus(focusNode: node, onFocusChange: (_) => setState(() {}), child: bar),
          );
        }
        if (!interactive) return bar;
        final hoverAt = _drag ?? _hover;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onHover: (e) => setState(() => _hover = _fraction(e.localPosition.dx, width)),
          onExit: (_) => setState(() => _hover = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => widget.onSeek!(_at(_fraction(d.localPosition.dx, width))),
            onHorizontalDragStart: (d) => setState(() => _drag = _fraction(d.localPosition.dx, width)),
            onHorizontalDragUpdate: (d) => setState(() => _drag = _fraction(d.localPosition.dx, width)),
            onHorizontalDragEnd: (_) {
              final f = _drag;
              setState(() => _drag = null);
              if (f != null) widget.onSeek!(_at(f));
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                bar,
                if (hoverAt != null)
                  Positioned(
                    left: (hoverAt * width - 60).clamp(0.0, width - 120),
                    bottom: 46,
                    width: 120,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xE614161E),
                          borderRadius: BorderRadius.circular(VRadius.xs),
                        ),
                        child: Text(formatClock(_at(hoverAt)), style: const TextStyle(fontSize: 20)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SeekPainter extends CustomPainter {
  _SeekPainter({required this.played, required this.buffered, required this.marks, required this.thick});

  final double played;
  final double buffered;
  final List<double> marks;
  final bool thick;

  @override
  void paint(Canvas canvas, Size size) {
    final h = thick ? 10.0 : 6.0;
    final y = size.height / 2;
    RRect bar(double from, double to) => RRect.fromRectAndRadius(
      Rect.fromLTRB(from * size.width, y - h / 2, to * size.width, y + h / 2),
      Radius.circular(h / 2),
    );
    canvas.drawRRect(bar(0, 1), Paint()..color = const Color(0x33FFFFFF));
    if (buffered > 0) canvas.drawRRect(bar(0, buffered), Paint()..color = const Color(0x59FFFFFF));
    if (played > 0) canvas.drawRRect(bar(0, played), Paint()..color = Colors.white);
    // 片头片尾的起止位置
    final mark = Paint()..color = const Color(0xFF0B0C10);
    for (final m in marks) {
      if (m <= 0 || m >= 1) continue;
      canvas.drawRect(Rect.fromCenter(center: Offset(m * size.width, y), width: 3, height: h), mark);
    }
    if (thick) canvas.drawCircle(Offset(played * size.width, y), 11, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_SeekPainter old) =>
      old.played != played || old.buffered != buffered || old.thick != thick || old.marks.length != marks.length;
}

/// 横向滚动的卡片列表：遥控器移动焦点时自动滚到可见；鼠标滚轮横向滚动
class _HorizontalList extends StatefulWidget {
  const _HorizontalList({required this.height, required this.children});

  final double height;
  final List<Widget> children;

  @override
  State<_HorizontalList> createState() => _HorizontalListState();
}

class _HorizontalListState extends State<_HorizontalList> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent && _controller.hasClients) {
          final p = _controller.position;
          _controller.jumpTo((p.pixels + e.scrollDelta.dy + e.scrollDelta.dx).clamp(0.0, p.maxScrollExtent));
        }
      },
      child: SizedBox(
        height: widget.height,
        child: FocusAutoScroll(
          alignment: 0.5,
          child: SingleChildScrollView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < widget.children.length; i++) ...[
                  if (i > 0) const SizedBox(width: 20),
                  widget.children[i],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「播放资源」面板：所有服务器上的版本，按 4K / 1080P / 其他分组
class SourcesPanel extends ConsumerStatefulWidget {
  const SourcesPanel({
    super.key,
    required this.serverId,
    required this.itemId,
    required this.currentSourceId,
    required this.onPick,
  });

  final String serverId;
  final String itemId;
  final String? currentSourceId;
  final ValueChanged<SourceOption> onPick;

  @override
  ConsumerState<SourcesPanel> createState() => _SourcesPanelState();
}

class _SourcesPanelState extends ConsumerState<SourcesPanel> {
  String? _group;

  bool _isCurrent(SourceOption o) => o.serverId == widget.serverId && o.source.id == widget.currentSourceId;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(sourceOptionsProvider((serverId: widget.serverId, itemId: widget.itemId)));
    final options = visibleSourceOptions(ref.read(configProvider), async.value ?? const <SourceOption>[]);
    final groups = [
      for (final g in const ['4K', '1080P', '其他'])
        if (options.any((o) => o.group == g)) g,
    ];
    final current = options.where(_isCurrent).firstOrNull;
    final group = _group ?? current?.group ?? groups.firstOrNull;
    final shown = options.where((o) => o.group == group).toList();
    final servers = ref.watch(configProvider.select((c) => c.servers));
    return SizedBox(
      height: 270,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('播放资源：', style: VText.label.copyWith(fontWeight: FontWeight.w600)),
              for (final g in groups)
                OsdTextButton(label: g, selected: g == group, onPressed: () => setState(() => _group = g)),
              if (async.isLoading) ...[
                const SizedBox(width: 20),
                Text('正在查找各服务器上的资源…', style: VText.small.copyWith(color: VColors.textTertiary)),
              ],
              if (async.hasError) ...[
                const SizedBox(width: 20),
                Text('查找资源失败', style: VText.small.copyWith(color: VColors.bad)),
              ],
            ],
          ),
          const SizedBox(height: 16),
          _HorizontalList(
            height: 180,
            children: [
              for (final o in shown)
                _SourceCard(
                  option: o,
                  current: _isCurrent(o),
                  autofocus: _isCurrent(o) || (current == null && identical(o, shown.first)),
                  logo: servers.where((s) => s.id == o.serverId).firstOrNull?.type,
                  onPick: () => widget.onPick(o),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.option,
    required this.current,
    required this.autofocus,
    required this.logo,
    required this.onPick,
  });

  final SourceOption option;
  final bool current;
  final bool autofocus;
  final ServerType? logo;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final s = option.source;
    const dim = TextStyle(fontSize: 20, color: Color(0xB3FFFFFF));
    return VFocusable(
      autofocus: autofocus,
      radius: VRadius.md,
      scale: 1.03,
      onActivate: onPick,
      builder: (context, focused) => AnimatedContainer(
        duration: VMotion.focus,
        width: 340,
        height: 160,
        padding: const EdgeInsets.fromLTRB(24, 20, 20, 18),
        decoration: BoxDecoration(
          color: focused ? const Color(0x40FFFFFF) : const Color(0x26FFFFFF),
          borderRadius: BorderRadius.circular(VRadius.md),
          border: Border.all(color: current ? const Color(0x99FFFFFF) : const Color(0x1AFFFFFF), width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Align(alignment: Alignment.centerLeft, child: VideoFormatBadges.of(s, height: 30)),
                ),
                Icon(
                  current ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  size: 26,
                  color: current ? const Color(0xFF7BE07B) : const Color(0x66FFFFFF),
                ),
              ],
            ),
            const Spacer(),
            Row(
              children: [
                const Icon(Icons.sd_storage_outlined, size: 20, color: Color(0xB3FFFFFF)),
                const SizedBox(width: 6),
                Text(s.size == null ? '—' : '${(s.size! / 1073741824).toStringAsFixed(2)} GB', style: dim),
                const SizedBox(width: 20),
                const Icon(Icons.speed_rounded, size: 20, color: Color(0xB3FFFFFF)),
                const SizedBox(width: 6),
                Text(s.bitrate == null ? '—' : '${(s.bitrate! / 1000000).toStringAsFixed(2)} Mbps', style: dim),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (logo != null) ...[
                  SizedBox(width: 22, height: 22, child: ServerTypeLogo(logo!)),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    option.serverName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: dim.copyWith(color: Colors.white),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 「选集」面板：本季所有集
class EpisodesPanel extends StatelessWidget {
  const EpisodesPanel({super.key, required this.episodes, required this.currentId, required this.onPick});

  final Future<List<MediaItem>> episodes;
  final String currentId;
  final ValueChanged<MediaItem> onPick;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 290,
      child: FutureBuilder<List<MediaItem>>(
        future: episodes,
        builder: (context, snap) {
          final eps = snap.data ?? const <MediaItem>[];
          final season = eps.where((e) => e.id == currentId).firstOrNull?.seasonNumber;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                snap.hasError
                    ? '获取集列表失败'
                    : snap.connectionState != ConnectionState.done
                    ? '正在获取集列表…'
                    : '选集${season == null ? '' : ' · 第 $season 季'} · 共 ${eps.length} 集',
                style: VText.label.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              _HorizontalList(
                height: 230,
                children: [
                  for (final e in eps) _EpisodeCard(episode: e, current: e.id == currentId, onPick: () => onPick(e)),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _EpisodeCard extends StatelessWidget {
  const _EpisodeCard({required this.episode, required this.current, required this.onPick});

  final MediaItem episode;
  final bool current;
  final VoidCallback onPick;

  static const width = 320.0;

  @override
  Widget build(BuildContext context) {
    final e = episode;
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          VFocusable(
            autofocus: current,
            radius: VRadius.md,
            scale: 1.04,
            onActivate: onPick,
            builder: (context, focused) => ClipRRect(
              borderRadius: BorderRadius.circular(VRadius.md),
              child: SizedBox(
                width: width,
                height: 180,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ServerImage(
                      serverId: e.serverId,
                      image: e.thumb ?? e.primary ?? e.backdrop,
                      width: width,
                      fallbackSeed: e.id,
                    ),
                    if (e.progress != null && e.progress! > 0)
                      Positioned(left: 0, right: 0, bottom: 0, child: ProgressLine(e.progress!)),
                    if (current)
                      Positioned(
                        left: 10,
                        top: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                            color: VColors.accent,
                            borderRadius: BorderRadius.circular(VRadius.xs),
                          ),
                          child: const Text('正在播放', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            [
              if (e.episodeNumber != null) '第 ${e.episodeNumber} 集',
              // 名字本身就是「第 N 集」时不重复
              if (!RegExp(r'^第\s*\d+\s*[集话話]$').hasMatch(e.name.trim())) e.name,
            ].join('  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 21, color: current ? Colors.white : const Color(0xCCFFFFFF)),
          ),
        ],
      ),
    );
  }
}

/// 一排按钮：←→ 按位置顺序移到左 / 右相邻的按钮，到两端停住；↑↓ 照常交给方向导航。
class OrderedButtonRow extends StatefulWidget {
  const OrderedButtonRow({super.key, required this.children, this.up});

  final List<Widget> children;

  /// 按 ↑ 去的地方（电视：进度条，它不在按钮正上方，按位置找不到）
  final FocusNode? up;

  @override
  State<OrderedButtonRow> createState() => _OrderedButtonRowState();
}

class _OrderedButtonRowState extends State<OrderedButtonRow> {
  final _group = FocusNode(debugLabel: 'osd-row', skipTraversal: true, canRequestFocus: false);

  @override
  void dispose() {
    _group.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Actions(
    actions: <Type, Action<Intent>>{DirectionalFocusIntent: _StepAction(_group, up: widget.up)},
    child: Focus(
      focusNode: _group,
      child: Row(children: widget.children),
    ),
  );
}

class _StepAction extends Action<DirectionalFocusIntent> {
  _StepAction(this.group, {this.up});

  final FocusNode group;
  final FocusNode? up;

  /// 接管左右（和指定了去处的 ↑）；其他方向不处理时继续交给外层（默认的方向导航）
  @override
  bool isEnabled(DirectionalFocusIntent intent, [BuildContext? context]) => switch (intent.direction) {
    TraversalDirection.left || TraversalDirection.right => true,
    TraversalDirection.up => up?.context != null,
    TraversalDirection.down => false,
  };

  @override
  Object? invoke(DirectionalFocusIntent intent) {
    if (intent.direction == TraversalDirection.up) {
      up!.requestFocus();
      return null;
    }
    final current = FocusManager.instance.primaryFocus;
    final buttons = group.traversalDescendants.where((n) => n.context != null).toList()
      ..sort((a, b) => a.rect.left.compareTo(b.rect.left));
    final i = current == null ? -1 : buttons.indexOf(current);
    if (i < 0) return null;
    final next = i + (intent.direction == TraversalDirection.right ? 1 : -1);
    if (next >= 0 && next < buttons.length) buttons[next].requestFocus();
    return null;
  }
}

/// 某个方向固定去一个节点；其他方向继续交给外层
class _JumpAction extends Action<DirectionalFocusIntent> {
  _JumpAction(this.direction, this.target);

  final TraversalDirection direction;
  final FocusNode target;

  @override
  bool isEnabled(DirectionalFocusIntent intent, [BuildContext? context]) =>
      intent.direction == direction && target.context != null;

  @override
  Object? invoke(DirectionalFocusIntent intent) {
    target.requestFocus();
    return null;
  }
}
