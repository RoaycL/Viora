import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/platform_profile.dart';
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

/// 调整字幕位置：画面上用半透明框标出字幕所在的位置，上方是百分比滑块。
///
/// 鼠标：拖动或点击滑块；键盘 / 遥控器：←→ 每次 1%，↑↓ 每次 5%（↑ 往上移），
/// 回车 / 返回 / 点击空白处完成。拖动时字幕实时跟着移动，松手（或完成）时再保存设置。
class SubtitlePositionAdjuster extends StatefulWidget {
  const SubtitlePositionAdjuster({
    super.key,
    required this.position,
    required this.scale,
    required this.onChanged,
    required this.onDone,
  });

  /// 和 mpv sub-pos 同义：100 = 默认的底部
  final int position;

  /// 字幕大小倍数：预览框的高度跟着它变
  final double scale;

  /// 实时预览（还没保存）
  final ValueChanged<int> onChanged;

  /// 完成：保存这个位置
  final ValueChanged<int> onDone;

  @override
  State<SubtitlePositionAdjuster> createState() => _SubtitlePositionAdjusterState();
}

class _SubtitlePositionAdjusterState extends State<SubtitlePositionAdjuster> {
  late int _lift = SubtitleLift.fromPosition(widget.position);
  final _focus = FocusNode(debugLabel: 'subtitle-position');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _set(int lift) {
    final v = lift.clamp(0, SubtitleLift.max);
    if (v == _lift) return;
    setState(() => _lift = v);
    widget.onChanged(SubtitleLift.toPosition(v));
  }

  void _done() => widget.onDone(SubtitleLift.toPosition(_lift));

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      _set(_lift + 1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _set(_lift - 1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _set(_lift + 5);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _set(_lift - 5);
    } else if (event is KeyDownEvent &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.escape ||
            key == LogicalKeyboardKey.goBack)) {
      _done();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: LayoutBuilder(
        builder: (context, c) {
          final size = c.biggest;
          final position = SubtitleLift.toPosition(_lift);
          final font = MpvSubtitleView.fontSize(size, widget.scale);
          // 两行字幕的高度（行高 1.3），上下各留一点余量
          final boxHeight = font * 1.3 * 2 + font * 0.6;
          final bottom = MpvSubtitleView.bottomOffset(size, position) - font * 0.3;
          return Stack(
            fit: StackFit.expand,
            children: [
              // 点空白处完成
              GestureDetector(behavior: HitTestBehavior.opaque, onTap: _done),
              // 字幕所在的区域：半透明框 + 示例文字
              Positioned(
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
              ),
              // 上方居中：标题、百分比、滑块和按钮
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
                          Text('字幕位置', style: VText.label.copyWith(color: VColors.textSecondary)),
                          const SizedBox(width: 16),
                          SizedBox(
                            width: 150,
                            child: Text(
                              _lift == 0 ? '默认' : '上移 $_lift%',
                              key: const ValueKey('subtitle-position-value'),
                              style: numericStyle(VText.rowTitle),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _LiftSlider(value: _lift, onChanged: _set),
                      const SizedBox(height: 8),
                      Text(
                        PlatformProfile.isTv ? '← → 微调 1%　↑ ↓ 调 5%　OK 完成' : '拖动滑块，或用 ← → 微调 1%、↑ ↓ 调 5%，回车完成',
                        style: VText.small.copyWith(fontSize: 16, color: VColors.textTertiary),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _TextButton(label: '恢复默认', onPressed: () => _set(0)),
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
}

/// 0–60% 的滑块：点击 / 拖动设置，滚轮每格 1%
class _LiftSlider extends StatelessWidget {
  const _LiftSlider({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  static const width = 520.0;

  void _at(double dx) => onChanged((dx / width * SubtitleLift.max).round());

  @override
  Widget build(BuildContext context) {
    final f = value / SubtitleLift.max;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) onChanged(value + (e.scrollDelta.dy < 0 ? 1 : -1));
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _at(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => _at(d.localPosition.dx),
          child: SizedBox(
            key: const ValueKey('subtitle-position-slider'),
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
                Container(
                  width: width * f,
                  height: 6,
                  decoration: BoxDecoration(color: const Color(0xFF5B8CFF), borderRadius: BorderRadius.circular(3)),
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

/// 面板里的小按钮（鼠标点击；键盘 / 遥控器用回车完成，不需要移动焦点）
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
