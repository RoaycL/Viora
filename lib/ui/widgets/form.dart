import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/platform_profile.dart';
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
    this.credential,
    this.textInputAction = TextInputAction.next,
  });

  /// 输入法右下角的键；默认「下一项」（回车后焦点移到下一个控件），其他（如搜索）回车后焦点留在输入框
  final TextInputAction textInputAction;

  /// 账号、密码、地址、Key：关闭输入法的自动纠错、联想和大小写（电视输入法常把 admin 改成 Admin、在末尾补空格）。
  /// 默认：密码框和网址框开启
  final bool? credential;

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
  final _eyeNode = FocusNode(debugLabel: 'VTextField.eye');

  /// 密码框：显示明文（电视上用遥控器输完可以核对一遍）
  bool _reveal = false;

  bool get _credential => widget.credential ?? (widget.obscure || widget.keyboardType == TextInputType.url);

  @override
  void initState() {
    super.initState();
    _node.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _node.dispose();
    _eyeNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
      _node.focusInDirection(key == LogicalKeyboardKey.arrowDown ? TraversalDirection.down : TraversalDirection.up);
      return KeyEventResult.handled;
    }
    // 密码框：光标在末尾时按 → 移到「显示密码」按钮
    if (key == LogicalKeyboardKey.arrowRight && widget.obscure && _node.hasFocus) {
      final sel = widget.controller.selection;
      if (!sel.isValid || sel.baseOffset >= widget.controller.text.length) {
        _eyeNode.requestFocus();
        return KeyEventResult.handled;
      }
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
    final compact = InfoTipScope.compact(context);
    final h = compact ? 52.0 : 68.0;
    final text = compact ? VText.label.copyWith(fontSize: 19) : VText.label;
    return SizedBox(
      width: widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.label, style: VText.caption.copyWith(color: VColors.textTertiary, fontSize: compact ? 17 : null)),
          SizedBox(height: compact ? 8 : 10),
          Row(
            children: [
              Expanded(
                child: Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: _onKey,
                  child: AnimatedContainer(
                    duration: VMotion.duration(context, VMotion.focus),
                    padding: EdgeInsets.symmetric(horizontal: compact ? 18 : 22),
                    height: h,
                    decoration: BoxDecoration(
                      color: focused ? const Color(0x24FFFFFF) : Color(compact ? 0x0AFFFFFF : 0x12FFFFFF),
                      borderRadius: BorderRadius.circular(VRadius.md),
                      border: Border.all(
                        color: focused ? Colors.white : Color(compact ? 0x14FFFFFF : 0x1FFFFFFF),
                        width: focused ? (compact ? 2 : 3) : 1,
                      ),
                    ),
                    alignment: Alignment.centerLeft,
                    child: TextField(
                      focusNode: _node,
                      controller: widget.controller,
                      autofocus: widget.autofocus,
                      obscureText: widget.obscure && !_reveal,
                      keyboardType: widget.obscure && _reveal ? TextInputType.visiblePassword : widget.keyboardType,
                      autocorrect: !_credential,
                      enableSuggestions: !_credential,
                      smartDashesType: _credential ? SmartDashesType.disabled : null,
                      smartQuotesType: _credential ? SmartQuotesType.disabled : null,
                      textCapitalization: TextCapitalization.none,
                      textInputAction: widget.textInputAction,
                      onSubmitted: (v) {
                        widget.onSubmitted?.call(v);
                        if (widget.textInputAction == TextInputAction.next) {
                          _node.focusInDirection(TraversalDirection.down);
                        }
                      },
                      cursorColor: VColors.accent,
                      style: text,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        isCollapsed: true,
                        hintText: widget.hint,
                        hintStyle: text.copyWith(color: VColors.textMuted),
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.obscure) ...[
                const SizedBox(width: 12),
                VFocusable(
                  focusNode: _eyeNode,
                  semanticLabel: _reveal ? '隐藏密码' : '显示密码',
                  radius: VRadius.md,
                  scale: 1.04,
                  showRing: false,
                  onActivate: () => setState(() => _reveal = !_reveal),
                  builder: (context, focused) => Tooltip(
                    excludeFromSemantics: true,
                    message: _reveal ? '隐藏密码' : '显示密码',
                    child: AnimatedContainer(
                      duration: VMotion.duration(context, VMotion.focus),
                      width: h,
                      height: h,
                      decoration: BoxDecoration(
                        color: focused ? Colors.white : Color(compact ? 0x0AFFFFFF : 0x12FFFFFF),
                        borderRadius: BorderRadius.circular(VRadius.md),
                      ),
                      child: Icon(
                        _reveal ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                        size: compact ? 22 : 28,
                        color: focused ? const Color(0xFF0B0C10) : Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (widget.helper != null) ...[
            const SizedBox(height: 8),
            Text(widget.helper!, style: VText.small.copyWith(color: VColors.textMuted, fontSize: compact ? 16 : null)),
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

  /// Windows 上较长的说明收进标题旁的「i」，鼠标悬停显示；短的状态说明（如「已开启」）和电视上照常显示在下面
  /// 只在设置页（[InfoTipScope] 里）这样做，其他页面的说明照常显示
  bool _tipOnly(BuildContext context) =>
      subtitle != null &&
      PlatformProfile.isDesktop &&
      subtitle!.characters.length > 16 &&
      InfoTipScope.enabled(context);

  @override
  Widget build(BuildContext context) {
    final compact = InfoTipScope.compact(context);
    final text = compact ? VText.label.copyWith(fontSize: 19) : VText.label;
    // 开关：紧凑时 52×30（原 64×36）
    final trackW = compact ? 52.0 : 64.0, trackH = compact ? 30.0 : 36.0, knob = compact ? 22.0 : 28.0;
    return VFocusable(
      semanticLabel: label,
      semanticValue: subtitle,
      toggled: value,
      radius: VRadius.md,
      scale: 1.02,
      alignment: Alignment.centerLeft,
      onActivate: () => onChanged(!value),
      builder: (context, focused) => AnimatedContainer(
        duration: VMotion.duration(context, VMotion.focus),
        width: width,
        constraints: BoxConstraints(minHeight: compact ? 56 : 72),
        padding: EdgeInsets.symmetric(horizontal: compact ? 20 : 24, vertical: compact ? 8 : 12),
        decoration: BoxDecoration(
          color: focused ? Color(compact ? 0x1AFFFFFF : 0x29FFFFFF) : Color(compact ? 0x08FFFFFF : 0x0DFFFFFF),
          borderRadius: BorderRadius.circular(VRadius.md),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_tipOnly(context))
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(child: Text(label, style: text)),
                        InfoTip(subtitle!),
                      ],
                    )
                  else ...[
                    Text(label, style: text),
                    if (subtitle != null)
                      Text(subtitle!, style: VText.small.copyWith(color: VColors.textTertiary, fontSize: compact ? 16 : null)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 16),
            AnimatedContainer(
              duration: VMotion.duration(context, VMotion.focus),
              width: trackW,
              height: trackH,
              padding: const EdgeInsets.all(4),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(
                color: value ? const Color(0xFF5B8CFF) : const Color(0x33FFFFFF),
                borderRadius: BorderRadius.circular(VRadius.md),
              ),
              child: Container(
                width: knob,
                height: knob,
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
    final (title, hint) = PlatformProfile.isDesktop && InfoTipScope.enabled(context) ? splitHint(label) : (label, null);
    final compact = InfoTipScope.compact(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(title, style: VText.caption.copyWith(color: VColors.textTertiary, fontSize: compact ? 17 : null))),
            if (hint != null) InfoTip(hint),
          ],
        ),
        SizedBox(height: compact ? 8 : 10),
        Row(
          children: [
            for (final (v, text) in options) ...[
              VFocusable(
                semanticLabel: text,
                selected: v == value,
                radius: 999,
                scale: 1.05,
                showRing: false,
                onActivate: () => onChanged(v),
                builder: (context, focused) {
                  final selected = v == value;
                  return AnimatedContainer(
                    duration: VMotion.duration(context, VMotion.focus),
                    height: compact ? 44 : 60,
                    padding: EdgeInsets.symmetric(horizontal: compact ? 22 : 30),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: focused
                          ? Colors.white
                          : (selected ? Color(compact ? 0x29FFFFFF : 0x33FFFFFF) : Color(compact ? 0x0AFFFFFF : 0x0DFFFFFF)),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: selected && !focused ? Color(compact ? 0xB3FFFFFF : 0xFFFFFFFF) : const Color(0x00000000),
                        width: compact ? 1.5 : 2,
                      ),
                    ),
                    child: Text(
                      text,
                      style: VText.label.copyWith(
                        fontSize: compact ? 18 : null,
                        color: focused ? const Color(0xFF0B0C10) : Colors.white,
                        fontWeight: selected ? (compact ? FontWeight.w600 : FontWeight.w700) : FontWeight.w400,
                      ),
                    ),
                  );
                },
              ),
              SizedBox(width: compact ? 10 : 14),
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
  Widget build(BuildContext context) {
    final compact = InfoTipScope.compact(context);
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 16 : 20),
      child: Text(text, style: compact ? VText.rowTitle.copyWith(fontSize: 24, fontWeight: FontWeight.w600) : VText.rowTitle),
    );
  }
}

/// 「标题（说明）」拆成标题和说明；没有括号说明时说明为 null
(String, String?) splitHint(String label) {
  final i = label.indexOf('（');
  if (i <= 0 || !label.endsWith('）')) return (label, null);
  return (label.substring(0, i), label.substring(i + 1, label.length - 1));
}

/// 包住的区域里，Windows 上较长的开关说明收进「i」（设置页用）
class InfoTipScope extends InheritedWidget {
  const InfoTipScope({super.key, required super.child});

  static bool enabled(BuildContext context) => context.dependOnInheritedWidgetOfExactType<InfoTipScope>() != null;

  /// Windows 设置页用更轻、更紧凑的表单尺寸（行更矮、字更小、底色更淡）；电视在几米外看，保持原来的尺寸
  static bool compact(BuildContext context) => PlatformProfile.isDesktop && enabled(context);

  @override
  bool updateShouldNotify(InfoTipScope oldWidget) => false;
}

/// 标题旁的「i」：鼠标悬停显示说明（Windows 设置页用，把长说明收起来）
class InfoTip extends StatelessWidget {
  const InfoTip(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      waitDuration: const Duration(milliseconds: 150),
      preferBelow: false,
      constraints: const BoxConstraints(maxWidth: 520),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: const Color(0xF21C1F2A), borderRadius: BorderRadius.circular(VRadius.sm)),
      textStyle: VText.small.copyWith(color: Colors.white, height: 1.5),
      child: const Padding(
        padding: EdgeInsets.only(left: 8),
        child: MouseRegion(
          cursor: SystemMouseCursors.help,
          child: Icon(Icons.info_outline_rounded, size: 20, color: VColors.textTertiary),
        ),
      ),
    );
  }
}
