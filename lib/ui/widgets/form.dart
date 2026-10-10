import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../focus/focusable.dart';

/// 大屏文本输入框。
///
/// 遥控器：↑↓ 离开输入框移到上下的控件（←→ 仍用于移动光标）；OK 弹出系统输入法。
class VTextField extends StatefulWidget {
  const VTextField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.obscure = false,
    this.autofocus = false,
    this.keyboardType,
    this.width,
    this.onSubmitted,
    this.helper,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  final bool autofocus;
  final TextInputType? keyboardType;

  /// null = 填满父级宽度
  final double? width;
  final ValueChanged<String>? onSubmitted;
  final String? helper;

  @override
  State<VTextField> createState() => _VTextFieldState();
}

class _VTextFieldState extends State<VTextField> {
  final _node = FocusNode(debugLabel: 'VTextField');

  @override
  void initState() {
    super.initState();
    _node.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
      _node.focusInDirection(key == LogicalKeyboardKey.arrowDown ? TraversalDirection.down : TraversalDirection.up);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.gameButtonA) {
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final focused = _node.hasFocus;
    return SizedBox(
      width: widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.label, style: VText.caption.copyWith(color: VColors.textTertiary)),
          const SizedBox(height: 10),
          Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _onKey,
            child: AnimatedContainer(
              duration: VMotion.focus,
              padding: const EdgeInsets.symmetric(horizontal: 22),
              height: 68,
              decoration: BoxDecoration(
                color: focused ? const Color(0x24FFFFFF) : const Color(0x12FFFFFF),
                borderRadius: BorderRadius.circular(VRadius.md),
                border: Border.all(color: focused ? Colors.white : const Color(0x1FFFFFFF), width: focused ? 3 : 1),
              ),
              alignment: Alignment.centerLeft,
              child: TextField(
                focusNode: _node,
                controller: widget.controller,
                autofocus: widget.autofocus,
                obscureText: widget.obscure,
                keyboardType: widget.keyboardType,
                textInputAction: TextInputAction.next,
                onSubmitted: (v) {
                  widget.onSubmitted?.call(v);
                  _node.focusInDirection(TraversalDirection.down);
                },
                cursorColor: VColors.accent,
                style: VText.label,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isCollapsed: true,
                  hintText: widget.hint,
                  hintStyle: VText.label.copyWith(color: VColors.textMuted),
                ),
              ),
            ),
          ),
          if (widget.helper != null) ...[
            const SizedBox(height: 8),
            Text(widget.helper!, style: VText.small.copyWith(color: VColors.textMuted)),
          ],
        ],
      ),
    );
  }
}

/// 开关行
class VToggle extends StatelessWidget {
  const VToggle({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.width,
  });

  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// null = 填满父级宽度
  final double? width;

  @override
  Widget build(BuildContext context) {
    return VFocusable(
      radius: VRadius.md,
      scale: 1.02,
      alignment: Alignment.centerLeft,
      onActivate: () => onChanged(!value),
      builder: (context, focused) => AnimatedContainer(
        duration: VMotion.focus,
        width: width,
        constraints: const BoxConstraints(minHeight: 72),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(
          color: focused ? const Color(0x29FFFFFF) : const Color(0x0DFFFFFF),
          borderRadius: BorderRadius.circular(VRadius.md),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: VText.label),
                  if (subtitle != null) Text(subtitle!, style: VText.small.copyWith(color: VColors.textTertiary)),
                ],
              ),
            ),
            const SizedBox(width: 16),
            AnimatedContainer(
              duration: VMotion.focus,
              width: 64,
              height: 36,
              padding: const EdgeInsets.all(4),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(
                color: value ? const Color(0xFF5B8CFF) : const Color(0x33FFFFFF),
                borderRadius: BorderRadius.circular(VRadius.md),
              ),
              child: Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单选胶囊组（如 Emby / Jellyfin）
class VChoice<T> extends StatelessWidget {
  const VChoice({super.key, required this.options, required this.value, required this.onChanged, required this.label});

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: VText.caption.copyWith(color: VColors.textTertiary)),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final (v, text) in options) ...[
              VFocusable(
                radius: 999,
                scale: 1.05,
                showRing: false,
                onActivate: () => onChanged(v),
                builder: (context, focused) {
                  final selected = v == value;
                  return AnimatedContainer(
                    duration: VMotion.focus,
                    height: 60,
                    padding: const EdgeInsets.symmetric(horizontal: 30),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: focused ? Colors.white : (selected ? const Color(0x33FFFFFF) : const Color(0x0DFFFFFF)),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: selected && !focused ? Colors.white : const Color(0x00000000),
                        width: 2,
                      ),
                    ),
                    child: Text(
                      text,
                      style: VText.label.copyWith(
                        color: focused ? const Color(0xFF0B0C10) : Colors.white,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(width: 14),
            ],
          ],
        ),
      ],
    );
  }
}

/// 页面内的分区标题
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Text(text, style: VText.rowTitle),
  );
}
