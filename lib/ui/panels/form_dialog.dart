import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../focus/focusable.dart';
import '../glass/glass.dart';
import '../widgets/buttons.dart';
import '../widgets/form.dart';

/// 居中的设置弹窗（磨砂玻璃）：放若干输入框，底部「取消 / 保存」。
/// [onSave] 返回 true 才关闭（校验失败时保持打开）。遥控器返回键 / Esc / 点击空白处取消。
Future<bool> showFormDialog(
  BuildContext context, {
  required String title,
  String? description,
  required List<Widget> children,
  required Future<bool> Function() onSave,
  String saveLabel = '保存',
}) async {
  final saved = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: const Color(0x8C07080B),
    transitionDuration: VMotion.focus,
    pageBuilder: (context, _, _) =>
        _FormDialog(title: title, description: description, onSave: onSave, saveLabel: saveLabel, children: children),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(scale: Tween(begin: 0.97, end: 1.0).animate(animation), child: child),
    ),
  );
  return saved ?? false;
}

class _FormDialog extends StatefulWidget {
  const _FormDialog({
    required this.title,
    required this.children,
    required this.onSave,
    required this.saveLabel,
    this.description,
  });

  final String title;
  final String? description;
  final List<Widget> children;
  final Future<bool> Function() onSave;
  final String saveLabel;

  @override
  State<_FormDialog> createState() => _FormDialogState();
}

class _FormDialogState extends State<_FormDialog> {
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (await widget.onSave() && mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: Glass(
          width: 920,
          radius: VRadius.panel,
          blur: 40,
          fill: const Color(0xCC14161E),
          padding: const EdgeInsets.fromLTRB(40, 36, 40, 32),
          child: FocusTraversalGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.title, style: VText.h2.copyWith(fontSize: 32)),
                if (widget.description != null) ...[
                  const SizedBox(height: 10),
                  Text(widget.description!, style: VText.caption.copyWith(color: VColors.textSecondary)),
                ],
                const SizedBox(height: 28),
                ...widget.children,
                const SizedBox(height: 32),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    PillButton(label: '取消', onPressed: () => Navigator.of(context).pop(false)),
                    const SizedBox(width: 16),
                    PillButton(
                      icon: Icons.check_rounded,
                      label: _saving ? '保存中…' : widget.saveLabel,
                      onPressed: _saving ? null : _save,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 设置项一行：标题 + 说明 + 右侧状态文字与「设置」按钮
class SettingsEntry extends StatelessWidget {
  const SettingsEntry({
    super.key,
    required this.title,
    required this.onConfigure,
    this.subtitle,
    this.status,
    this.trailing = const [],
  });

  final String title;
  final String? subtitle;

  /// 右侧状态（如"已填写 Key"）
  final String? status;
  final VoidCallback onConfigure;

  /// 设置按钮前的其他控件（开关、上移下移等）
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 14, 14, 14),
      decoration: BoxDecoration(color: const Color(0x0DFFFFFF), borderRadius: BorderRadius.circular(VRadius.md)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: VText.label),
                if (subtitle != null) Text(subtitle!, style: VText.small.copyWith(color: VColors.textTertiary)),
              ],
            ),
          ),
          if (status != null) ...[
            Text(status!, style: VText.small.copyWith(color: VColors.textSecondary)),
            const SizedBox(width: 16),
          ],
          for (final w in trailing) ...[w, const SizedBox(width: 12)],
          SmallIconButton(icon: Icons.tune_rounded, label: '设置', semanticLabel: '设置$title', onPressed: onConfigure),
        ],
      ),
    );
  }
}

/// 小号图标按钮（设置、上移、下移）：比胶囊按钮紧凑，适合放在设置行里
class SmallIconButton extends StatelessWidget {
  const SmallIconButton({super.key, required this.icon, required this.onPressed, this.label, this.semanticLabel})
    : assert(label != null || semanticLabel != null);

  final IconData icon;
  final String? label;
  final String? semanticLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: semanticLabel ?? label!,
      excludeFromSemantics: true,
      child: VFocusable(
        semanticLabel: semanticLabel ?? label,
        radius: VRadius.sm,
        scale: 1.04,
        showRing: false,
        onActivate: onPressed,
        builder: (context, focused) => Opacity(
          opacity: enabled ? 1 : 0.55,
          child: AnimatedContainer(
            duration: VMotion.duration(context, VMotion.focus),
            height: 48,
            padding: EdgeInsets.symmetric(horizontal: label == null ? 12 : 16),
            decoration: BoxDecoration(
              color: focused ? Colors.white : const Color(0x14FFFFFF),
              borderRadius: BorderRadius.circular(VRadius.sm),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 22, color: focused ? const Color(0xFF0B0C10) : Colors.white),
                if (label != null) ...[
                  const SizedBox(width: 8),
                  Text(label!, style: TextStyle(fontSize: 20, color: focused ? const Color(0xFF0B0C10) : Colors.white)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 紧凑开关（设置行里与「设置」按钮并排）
class SmallSwitch extends StatelessWidget {
  const SmallSwitch({super.key, required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return VFocusable(
      semanticLabel: label,
      toggled: value,
      radius: VRadius.md,
      scale: 1.04,
      showRing: false,
      onActivate: () => onChanged(!value),
      builder: (context, focused) => AnimatedContainer(
        duration: VMotion.duration(context, VMotion.focus),
        width: 64,
        height: 36,
        padding: const EdgeInsets.all(4),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        decoration: BoxDecoration(
          color: value ? const Color(0xFF5B8CFF) : const Color(0x33FFFFFF),
          borderRadius: BorderRadius.circular(VRadius.md),
          border: Border.all(color: focused ? Colors.white : const Color(0x00000000), width: 2),
        ),
        child: Container(
          width: 24,
          height: 24,
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

/// 居中的确认弹窗（删除、退出等需要用户确认的操作）：标题 + 说明 + 「取消 / 确认」两个按钮。
/// 返回 true 表示确认，false 表示按了「取消」，null 表示返回键 / Esc / 点击空白处关掉。
/// 焦点默认在「取消」上，避免误按删除。
Future<bool?> showConfirmDialog(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = '确认',
  String cancelLabel = '取消',
  IconData confirmIcon = Icons.check_rounded,
  bool destructive = false,
  bool focusConfirm = false,
}) {
  return showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: const Color(0x8C07080B),
    transitionDuration: VMotion.focus,
    pageBuilder: (context, _, _) => Center(
      child: Material(
        type: MaterialType.transparency,
        child: Glass(
          width: 640,
          radius: VRadius.panel,
          blur: 40,
          fill: const Color(0xCC14161E),
          padding: const EdgeInsets.fromLTRB(40, 36, 40, 32),
          child: FocusTraversalGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: VText.h2.copyWith(fontSize: 30)),
                if (message != null) ...[
                  const SizedBox(height: 12),
                  Text(message, style: VText.caption.copyWith(color: VColors.textSecondary)),
                ],
                const SizedBox(height: 32),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    PillButton(
                      label: cancelLabel,
                      autofocus: !focusConfirm,
                      onPressed: () => Navigator.of(context).pop(false),
                    ),
                    const SizedBox(width: 16),
                    _ConfirmButton(
                      label: confirmLabel,
                      icon: confirmIcon,
                      destructive: destructive,
                      autofocus: focusConfirm,
                      onPressed: () => Navigator.of(context).pop(true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(scale: Tween(begin: 0.97, end: 1.0).animate(animation), child: child),
    ),
  );
}

/// 确认按钮：删除类操作用红色文字，一眼看出是危险操作
class _ConfirmButton extends StatelessWidget {
  const _ConfirmButton({
    required this.label,
    required this.icon,
    required this.destructive,
    required this.autofocus,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool destructive;
  final bool autofocus;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (!destructive) return PillButton(label: label, icon: icon, autofocus: autofocus, onPressed: onPressed);
    return VFocusable(
      autofocus: autofocus,
      onActivate: onPressed,
      semanticLabel: label,
      radius: VRadius.pill,
      scale: 1.04,
      showRing: false,
      builder: (context, focused) {
        final compact = InfoTipScope.compact(context);
        return AnimatedContainer(
          duration: VMotion.duration(context, VMotion.focus),
          height: compact ? 48 : 68,
          padding: EdgeInsets.only(left: compact ? 20 : 28, right: compact ? 24 : 32),
          decoration: ShapeDecoration(
            shape: const StadiumBorder(),
            color: focused ? VColors.bad : const Color(0x33FF6B6B),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: compact ? 21 : 28, color: focused ? Colors.white : VColors.bad),
              SizedBox(width: compact ? 10 : 12),
              Text(
                label,
                style: TextStyle(
                  fontSize: compact ? 19 : 24,
                  fontWeight: FontWeight.w600,
                  color: focused ? Colors.white : VColors.bad,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
