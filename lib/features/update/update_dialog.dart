import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../ui/glass/glass.dart';
import '../../ui/rows/cards.dart';
import '../../ui/widgets/buttons.dart';
import 'update_controller.dart';
import 'update_source.dart';

/// 发现新版本时的弹窗：更新说明 + 立即更新 / 稍后。下载进度、安装状态都在这里展示。
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: const Color(0x9907080B),
    transitionDuration: VMotion.scroll,
    pageBuilder: (context, _, _) => _UpdateDialog(info: info),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(animation), child: child),
    ),
  );
}

class _UpdateDialog extends ConsumerWidget {
  const _UpdateDialog({required this.info});

  final UpdateInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateControllerProvider);
    final controller = ref.read(updateControllerProvider.notifier);
    final busy = state is UpdateDownloading || (state is UpdateInstalling && !state.needsPermission);

    final String? status = switch (state) {
      UpdateDownloading(:final received, :final total) =>
        '正在下载 ${_mb(received)}${total == null ? '' : ' / ${_mb(total)}'}',
      UpdateInstalling(needsPermission: true) => '请在打开的设置页中允许 Viora "安装未知应用"，返回后再按一次"立即更新"。',
      UpdateInstalling() => '已打开系统安装界面，按提示完成安装。',
      UpdateFailed(:final message) => message,
      _ => null,
    };

    return Center(
      child: Glass(
        width: 880,
        radius: VRadius.panel,
        blur: 40,
        fill: const Color(0xB312141C),
        padding: const EdgeInsets.fromLTRB(48, 44, 48, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                const Text('发现新版本', style: VText.h2),
                const SizedBox(width: 16),
                Text(info.label, style: VText.h2.copyWith(color: VColors.accent)),
                const Spacer(),
                if (info.size != null)
                  Text(_mb(info.size!), style: VText.caption.copyWith(color: VColors.textTertiary)),
              ],
            ),
            const SizedBox(height: 20),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: SingleChildScrollView(
                child: Text(
                  info.notes.isEmpty ? '本次更新没有填写说明。' : info.notes,
                  style: VText.label.copyWith(color: VColors.textSecondary, height: 1.6),
                ),
              ),
            ),
            const SizedBox(height: 28),
            if (state is UpdateDownloading) ...[
              ProgressLine(state.progress ?? 0, height: 8),
              const SizedBox(height: 14),
            ],
            if (status != null) ...[
              Text(
                status,
                style: VText.caption.copyWith(color: state is UpdateFailed ? VColors.bad : VColors.textSecondary),
              ),
              const SizedBox(height: 24),
            ],
            Row(
              children: [
                PillButton(
                  autofocus: true,
                  large: true,
                  icon: Icons.system_update_alt_rounded,
                  label: switch (state) {
                    UpdateDownloading() => '下载中…',
                    UpdateFailed() => '重试',
                    _ => '立即更新',
                  },
                  onPressed: busy ? null : () => controller.downloadAndInstall(info),
                ),
                const SizedBox(width: 40),
                PillButton(label: '稍后', onPressed: () => Navigator.of(context).pop()),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _mb(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
