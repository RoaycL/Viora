import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../focus/focusable.dart';
import '../glass/glass.dart';
import '../widgets/buttons.dart';

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
          SmallIconButton(icon: Icons.tune_rounded, label: '设置', onPressed: onConfigure),
        ],
      ),
    );
  }
}

/// 小号图标按钮（设置、上移、下移）：比胶囊按钮紧凑，适合放在设置行里
class SmallIconButton extends StatelessWidget {
  const SmallIconButton({super.key, required this.icon, required this.onPressed, this.label});

  final IconData icon;
  final String? label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: VFocusable(
        radius: VRadius.sm,
        scale: 1.04,
        showRing: false,
        onActivate: onPressed,
        builder: (context, focused) => AnimatedContainer(
          duration: VMotion.focus,
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
    );
  }
}

/// 紧凑开关（设置行里与「设置」按钮并排）
class SmallSwitch extends StatelessWidget {
  const SmallSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return VFocusable(
      radius: VRadius.md,
      scale: 1.04,
      showRing: false,
      onActivate: () => onChanged(!value),
      builder: (context, focused) => AnimatedContainer(
        duration: VMotion.focus,
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
