import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/input/back_handler.dart';
import '../../app/theme.dart';
import '../../player/mpv_engine.dart';
import '../../ui/focus/focusable.dart';
import '../../ui/glass/glass.dart';

/// 「字幕位置」调整：上移的百分比（画面高度的 %）和 mpv sub-pos 的换算。0% = 默认的底部位置
abstract final class SubtitleLift {
  /// 最多上移到画面高度的 60%
  static const max = 60;

  static int fromPosition(int position) => (100 - position).clamp(0, max);
  static int toPosition(int lift) => 100 - lift.clamp(0, max);

  static String label(int position) {
    final lift = fromPosition(position);
    return lift == 0 ? '默认' : '上移 $lift%';
  }
}

/// 播放页里用滑块精确调整的一项（Windows）：字幕位置、字幕延迟、弹幕时间偏移
class SliderSpec {
  const SliderSpec({
    required this.title,
    required this.min,
    required this.max,
    required this.fine,
    required this.coarse,
    required this.defaultValue,
    required this.format,
    required this.hint,
  });

  final String title;
  final double min;
  final double max;

  /// ← → 每次的步长，也是拖动时取整的单位
  final double fine;

  /// ↑ ↓ 每次的步长
  final double coarse;
  final double defaultValue;
  final String Function(double v) format;

  /// 面板下方的操作说明
  final String hint;

  /// 字幕位置：0–60%（上移画面高度的百分之几）
  static final subtitleLift = SliderSpec(
    title: '字幕位置',
    min: 0,
    max: SubtitleLift.max.toDouble(),
    fine: 1,
    coarse: 5,
    defaultValue: 0,
    format: (v) => v == 0 ? '默认' : '上移 ${v.round()}%',
    hint: '拖动滑块，或用 ← → 微调 1%、↑ ↓ 调 5%，回车完成',
  );

  /// 字幕延迟：±10 秒，0.1 秒一档（正数 = 字幕推后）
  static final subtitleDelay = SliderSpec(
    title: '字幕延迟',
    min: -10,
    max: 10,
    fine: 0.1,
    coarse: 1,
    defaultValue: 0,
    format: (v) => _seconds(v, '推后', '提前'),
    hint: '拖动滑块，或用 ← → 微调 0.1 秒、↑ ↓ 调 1 秒，回车完成',
  );

  /// 弹幕时间偏移：±30 秒，0.1 秒一档（正数 = 弹幕延后）
  static final danmakuShift = SliderSpec(
    title: '弹幕时间',
    min: -30,
    max: 30,
    fine: 0.1,
    coarse: 1,
    defaultValue: 0,
    format: (v) => _seconds(v, '延后', '提前'),
    hint: '拖动滑块，或用 ← → 微调 0.1 秒、↑ ↓ 调 1 秒，回车完成',
  );

  static String _seconds(double v, String later, String earlier) =>
      v.abs() < 0.05 ? '不偏移' : '${v > 0 ? later : earlier} ${v.abs().toStringAsFixed(1)} 秒';

  /// 按步长取整并限制在范围内（避免 0.1 累加出 0.30000000004 这样的值）
  double snap(double v) {
    final steps = ((v - min) / fine).round();
    // 用整数步数换算后再按 1e-6 取整，避免 -10 + 103 * 0.1 这类浮点误差
    final v2 = ((min + steps * fine) * 1e6).roundToDouble() / 1e6;
    return v2.clamp(min, max);
  }
}

/// 滑块调整面板（只在 Windows 上用；电视仍是原来的菜单）。
///
/// 上方居中：标题、当前值、滑块、「恢复默认」「完成」。拖动 / 点击滑块、滚轮、方向键都可以调整，
/// 改动实时生效（[onChanged]），回车 / Esc / 点空白处完成（[onDone]）。
/// 调字幕位置时传 [subtitleScale]：画面上用半透明框标出字幕所在的位置。
class SliderAdjuster extends StatefulWidget {
  const SliderAdjuster({
    super.key,
    required this.spec,
    required this.value,
    required this.onChanged,
    required this.onDone,
    this.subtitleScale,
  });

  final SliderSpec spec;
  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onDone;

  /// 非 null：显示字幕位置预览框（[value] 是上移的百分比）
  final double? subtitleScale;

  @override
  State<SliderAdjuster> createState() => _SliderAdjusterState();
}

class _SliderAdjusterState extends State<SliderAdjuster> {
  late double _value = widget.spec.snap(widget.value);
  final _focus = FocusNode(debugLabel: 'slider-adjuster');
  Timer? _refocus;

  @override
  void initState() {
    super.initState();
    // 打开它的菜单关闭时，焦点会还给菜单下面原来的按钮：这一帧之后、菜单收起动画结束后各要一次焦点
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
    _refocus = Timer(const Duration(milliseconds: 300), () {
      if (mounted && !_focus.hasFocus) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _refocus?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _set(double v) {
    final s = widget.spec.snap(v);
    if (s == _value) return;
    setState(() => _value = s);
    widget.onChanged(s);
  }

  void _done() => widget.onDone(_value);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final spec = widget.spec;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      _set(_value + spec.fine);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _set(_value - spec.fine);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _set(_value + spec.coarse);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _set(_value - spec.coarse);
    } else if (event is KeyDownEvent &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.select)) {
      _done();
    } else if (event is KeyDownEvent && (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack)) {
      // 和播放页的返回键一样：之后到达的系统返回是这次按键的重复，不再退出播放
      BackDedup.markKey();
      _done();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final scale = widget.subtitleScale;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: LayoutBuilder(
        builder: (context, c) {
          final size = c.biggest;
          return Stack(
            fit: StackFit.expand,
            children: [
              // 点空白处完成
              GestureDetector(behavior: HitTestBehavior.opaque, onTap: _done),
              if (scale != null) _subtitlePreview(size, scale),
              Align(
                alignment: const Alignment(0, -0.62),
                child: Glass(
                  radius: VRadius.panel,
                  padding: const EdgeInsets.fromLTRB(32, 24, 32, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(spec.title, style: VText.label.copyWith(color: VColors.textSecondary)),
                          const SizedBox(width: 16),
                          ConstrainedBox(
                            constraints: const BoxConstraints(minWidth: 170),
                            child: Text(
                              spec.format(_value),
                              key: const ValueKey('slider-adjuster-value'),
                              style: numericStyle(VText.rowTitle),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _Slider(spec: spec, value: _value, onChanged: _set),
                      const SizedBox(height: 8),
                      Text(spec.hint, style: VText.small.copyWith(fontSize: 16, color: VColors.textTertiary)),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _TextButton(label: '恢复默认', onPressed: () => _set(spec.defaultValue)),
                          const SizedBox(width: 12),
                          _TextButton(label: '完成', primary: true, onPressed: _done),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 字幕所在的区域：半透明框 + 示例文字（和真实字幕用同一个算法算位置）
  Widget _subtitlePreview(Size size, double scale) {
    final position = SubtitleLift.toPosition(_value.round());
    final font = MpvSubtitleView.fontSize(size, scale);
    // 两行字幕的高度（行高 1.3），上下各留一点余量
    final boxHeight = font * 1.3 * 2 + font * 0.6;
    final bottom = MpvSubtitleView.bottomOffset(size, position) - font * 0.3;
    return Positioned(
      left: size.width * 0.12,
      right: size.width * 0.12,
      bottom: bottom.clamp(0.0, size.height - boxHeight),
      height: boxHeight,
      child: IgnorePointer(
        child: Container(
          key: const ValueKey('subtitle-position-preview'),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0x335B8CFF),
            borderRadius: BorderRadius.circular(VRadius.md),
            border: Border.all(color: const Color(0xCC8FB0FF), width: 2),
          ),
          child: Text(
            '字幕显示在这里',
            style: TextStyle(
              fontSize: font,
              fontWeight: FontWeight.w500,
              color: const Color(0xE6FFFFFF),
              shadows: const [Shadow(color: Color(0x99000000), blurRadius: 8)],
            ),
          ),
        ),
      ),
    );
  }
}

/// 滑块：点击 / 拖动设置，滚轮每格一个小步长。范围跨过 0 时（延迟）在 0 处画一条刻度，填充从 0 画到当前值
class _Slider extends StatelessWidget {
  const _Slider({required this.spec, required this.value, required this.onChanged});

  final SliderSpec spec;
  final double value;
  final ValueChanged<double> onChanged;

  static const width = 520.0;

  double _fraction(double v) => ((v - spec.min) / (spec.max - spec.min)).clamp(0.0, 1.0);

  void _at(double dx) => onChanged(spec.min + (dx / width).clamp(0.0, 1.0) * (spec.max - spec.min));

  @override
  Widget build(BuildContext context) {
    final f = _fraction(value);
    final zero = spec.min < 0 && spec.max > 0 ? _fraction(0) : 0.0;
    final from = f < zero ? f : zero, to = f < zero ? zero : f;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) onChanged(value + (e.scrollDelta.dy < 0 ? spec.fine : -spec.fine));
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _at(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => _at(d.localPosition.dx),
          child: SizedBox(
            key: const ValueKey('slider-adjuster-slider'),
            width: width,
            height: 44,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 6,
                  decoration: BoxDecoration(color: const Color(0x4DFFFFFF), borderRadius: BorderRadius.circular(3)),
                ),
                if (zero > 0)
                  Positioned(
                    left: width * zero - 1,
                    child: Container(width: 2, height: 16, color: const Color(0x99FFFFFF)),
                  ),
                Positioned(
                  left: width * from,
                  width: width * (to - from),
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(color: const Color(0xFF5B8CFF), borderRadius: BorderRadius.circular(3)),
                  ),
                ),
                Positioned(
                  left: width * f - 11,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: Color(0x66000000), blurRadius: 8)],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 面板里的小按钮（鼠标点击；键盘用回车完成，不需要移动焦点）
class _TextButton extends StatelessWidget {
  const _TextButton({required this.label, required this.onPressed, this.primary = false});

  final String label;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return ExcludeFocus(
      child: VFocusable(
        semanticLabel: label,
        radius: 999,
        scale: 1.04,
        showRing: false,
        onActivate: onPressed,
        builder: (context, focused) => Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: primary ? Colors.white : const Color(0x1FFFFFFF),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: VText.label.copyWith(
              fontSize: 19,
              fontWeight: FontWeight.w600,
              color: primary ? const Color(0xFF0B0C10) : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
