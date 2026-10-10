import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/input/intents.dart';
import '../../app/theme.dart';

/// 可聚焦元素的统一外壳（docs/07-input-control.md §2）。
///
/// - 焦点态：放大 + 白色描边 + 外发光（[builder] 也能拿到 focused 自行绘制）
/// - 确认键：松开时执行 [onActivate]；按住 ≥500ms 改为 [onMenu]
/// - 鼠标：悬停即聚焦，左键执行，右键菜单
/// - 菜单键（MenuIntent）：[onMenu]
class VFocusable extends StatefulWidget {
  const VFocusable({
    super.key,
    required this.builder,
    this.focusNode,
    this.autofocus = false,
    this.onActivate,
    this.onMenu,
    this.onFocusChange,
    this.radius = VRadius.card,
    this.scale = VMotion.focusScale,
    this.alignment = Alignment.center,
    this.showRing = true,
    this.ringWidth = 3,
  });

  final Widget Function(BuildContext context, bool focused) builder;
  final FocusNode? focusNode;
  final bool autofocus;
  final VoidCallback? onActivate;
  final VoidCallback? onMenu;
  final ValueChanged<bool>? onFocusChange;
  final double radius;
  final double scale;
  final Alignment alignment;
  final bool showRing;
  final double ringWidth;

  static const longPress = Duration(milliseconds: 500);

  @override
  State<VFocusable> createState() => _VFocusableState();
}

class _VFocusableState extends State<VFocusable> {
  FocusNode? _ownNode;
  FocusNode get _node => widget.focusNode ?? (_ownNode ??= FocusNode(debugLabel: 'VFocusable'));

  bool _focused = false;
  Timer? _pressTimer;
  bool _pressed = false;
  bool _longPressFired = false;

  @override
  void dispose() {
    _pressTimer?.cancel();
    _ownNode?.dispose();
    super.dispose();
  }

  void _handleFocusChange(bool focused) {
    setState(() => _focused = focused);
    widget.onFocusChange?.call(focused);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!confirmKeys.contains(event.logicalKey)) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      _pressed = true;
      _longPressFired = false;
      _pressTimer?.cancel();
      if (widget.onMenu != null) {
        _pressTimer = Timer(VFocusable.longPress, () {
          _longPressFired = true;
          widget.onMenu?.call();
        });
      }
    } else if (event is KeyUpEvent) {
      _pressTimer?.cancel();
      if (_pressed && !_longPressFired) widget.onActivate?.call();
      _pressed = false;
    }
    // KeyRepeatEvent 也吞掉，避免长按时触发其他快捷键。
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(context, _focused);
    final radius = BorderRadius.circular(widget.radius);

    Widget decorated = AnimatedContainer(
      duration: VMotion.focus,
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: _focused && widget.showRing
            ? const [
                BoxShadow(color: Color(0x1FFFFFFF), spreadRadius: 6),
                BoxShadow(color: VColors.focusGlow, blurRadius: 50, offset: Offset(0, 18)),
              ]
            : const [],
      ),
      foregroundDecoration: _focused && widget.showRing
          ? BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: VColors.focusRing, width: widget.ringWidth),
            )
          : null,
      child: child,
    );

    decorated = AnimatedScale(
      scale: _focused ? widget.scale : 1,
      duration: VMotion.focus,
      curve: Curves.easeOut,
      alignment: widget.alignment,
      child: decorated,
    );

    return Actions(
      actions: <Type, Action<Intent>>{
        if (widget.onMenu != null) MenuIntent: CallbackAction<MenuIntent>(onInvoke: (_) => widget.onMenu!()),
      },
      child: Focus(
        focusNode: _node,
        autofocus: widget.autofocus,
        onFocusChange: _handleFocusChange,
        onKeyEvent: _handleKey,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          // 只响应真实的鼠标移动（onHover），不用 onEnter：
          // 键盘滚动页面时静止的指针会"进入"新元素，不能因此抢走焦点。
          onHover: (_) {
            if (!_node.hasFocus) _node.requestFocus();
          },
          child: Listener(
            onPointerDown: (event) {
              if (event.buttons == kSecondaryMouseButton) {
                _node.requestFocus();
                widget.onMenu?.call();
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _node.requestFocus();
                widget.onActivate?.call();
              },
              child: decorated,
            ),
          ),
        ),
      ),
    );
  }
}
