import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/input/intents.dart';
import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import 'input_mode.dart';

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
    this.enabled = true,
    this.semanticLabel,
    this.semanticValue,
    this.selected,
    this.toggled,
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

  /// 不可用控件仍能接收焦点，以免电视上的异步播放按钮使行导航失去锚点。
  /// 没有操作回调时也视为不可用，不响应确认、鼠标或辅助技术操作。
  final bool enabled;
  final String? semanticLabel;
  final String? semanticValue;
  final bool? selected;
  final bool? toggled;

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
  LogicalKeyboardKey? _pressKey;

  bool get _enabled => widget.enabled && (widget.onActivate != null || widget.onMenu != null);

  void _cancelPress() {
    _pressTimer?.cancel();
    _pressKey = null;
    _longPressFired = false;
    if (_pressed) setState(() => _pressed = false);
  }

  @override
  void didUpdateWidget(VFocusable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled || oldWidget.focusNode != widget.focusNode) _cancelPress();
  }

  @override
  void dispose() {
    _pressTimer?.cancel();
    _ownNode?.dispose();
    super.dispose();
  }

  void _handleFocusChange(bool focused) {
    if (!focused) _cancelPress();
    setState(() => _focused = focused);
    widget.onFocusChange?.call(focused);
  }

  void _activate() {
    if (!_enabled || widget.onActivate == null) return;
    _cancelPress();
    _node.requestFocus();
    widget.onActivate!();
  }

  void _menu() {
    if (!_enabled || widget.onMenu == null) return;
    _cancelPress();
    _node.requestFocus();
    widget.onMenu!();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!confirmKeys.contains(event.logicalKey)) return KeyEventResult.ignored;
    if (!_enabled) return KeyEventResult.handled;
    if (event is KeyDownEvent) {
      if (_pressKey != null) return KeyEventResult.handled;
      _pressKey = event.logicalKey;
      setState(() => _pressed = true);
      _longPressFired = false;
      _pressTimer?.cancel();
      if (widget.onMenu != null) {
        _pressTimer = Timer(VFocusable.longPress, () {
          if (!mounted || !_node.hasFocus || !_enabled || _pressKey == null) return;
          _longPressFired = true;
          setState(() => _pressed = false);
          widget.onMenu?.call();
        });
      }
    } else if (event is KeyUpEvent && event.logicalKey == _pressKey) {
      final activate = _pressed && !_longPressFired;
      _cancelPress();
      if (activate) _activate();
    }
    // KeyRepeatEvent 也吞掉，避免长按时触发其他快捷键。
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(context, _focused && _enabled);
    final radius = BorderRadius.circular(widget.radius);
    final reduced = VMotion.reduced(context);
    final duration = VMotion.duration(context, VMotion.focus);
    final showRing = _focused && (widget.showRing || !_enabled);
    // Windows 离屏幕近：放大幅度减半、光晕更淡、描边更细；电视保持远距离也能看清的焦点效果
    final desktop = PlatformProfile.isDesktop;
    final scale = desktop ? 1 + (widget.scale - 1) * 0.5 : widget.scale;

    Widget decorated = AnimatedContainer(
      duration: duration,
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: showRing && _enabled && !reduced
            ? desktop
                  ? const [BoxShadow(color: Color(0x40000000), blurRadius: 24, offset: Offset(0, 10))]
                  : const [
                      BoxShadow(color: Color(0x1FFFFFFF), spreadRadius: 6),
                      BoxShadow(color: VColors.focusGlow, blurRadius: 50, offset: Offset(0, 18)),
                    ]
            : const [],
      ),
      foregroundDecoration: showRing || _pressed
          ? BoxDecoration(
              borderRadius: radius,
              color: _pressed ? const Color(0x1F000000) : null,
              border: showRing ? Border.all(color: VColors.focusRing, width: desktop ? 2 : widget.ringWidth) : null,
            )
          : null,
      child: child,
    );

    if (!reduced) {
      decorated = AnimatedScale(
        scale: _enabled ? (_focused ? scale : 1.0) * (_pressed ? 0.98 : 1.0) : 1.0,
        duration: duration,
        curve: Curves.easeOut,
        alignment: widget.alignment,
        child: decorated,
      );
    }

    return Semantics(
      container: true,
      button: widget.toggled == null,
      enabled: _enabled,
      focusable: true,
      focused: _focused,
      selected: widget.selected,
      toggled: widget.toggled,
      label: widget.semanticLabel,
      value: widget.semanticValue,
      // 明确命名的控件由这里统一朗读，避免 Logo、图标和可视文字重复命名。
      excludeSemantics: widget.semanticLabel != null,
      onTap: _enabled && widget.onActivate != null ? _activate : null,
      onLongPress: _enabled && widget.onMenu != null ? _menu : null,
      child: Actions(
        actions: <Type, Action<Intent>>{
          if (widget.onMenu != null) MenuIntent: CallbackAction<MenuIntent>(onInvoke: (_) => _menu()),
        },
        child: Focus(
          focusNode: _node,
          autofocus: widget.autofocus,
          includeSemantics: false,
          onFocusChange: _handleFocusChange,
          onKeyEvent: _handleKey,
          child: MouseRegion(
            cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
            // 只响应真实的鼠标移动（onHover），不用 onEnter：
            // 键盘滚动页面时静止的指针会"进入"新元素，不能因此抢走焦点。
            onHover: (_) {
              InputMode.markPointer();
              if (!_node.hasFocus) _node.requestFocus();
            },
            child: Listener(
              onPointerDown: (event) {
                InputMode.markPointer();
                if (event.buttons == kSecondaryMouseButton) {
                  _menu();
                } else if (_enabled && widget.onActivate != null && event.buttons == kPrimaryMouseButton) {
                  setState(() => _pressed = true);
                }
              },
              onPointerCancel: (_) => _cancelPress(),
              child: GestureDetector(
                excludeFromSemantics: true,
                behavior: HitTestBehavior.opaque,
                // 不可用控件仍消费点击，防止事件落到背后的 Hero 或播放画面。
                onTap: _activate,
                onTapUp: (_) => _cancelPress(),
                onTapCancel: _cancelPress,
                child: decorated,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
