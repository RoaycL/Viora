import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../ui/focus/focusable.dart';
import '../../ui/glass/glass.dart';
import '../../ui/widgets/buttons.dart';
import '../update/update_controller.dart';
import '../update/update_dialog.dart';

/// 设置（M0：关于与更新；其余分类随里程碑开放，见 docs/06-ui-design.md §9）。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  String _version = '';
  String _source = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = ref.read(updateControllerProvider.notifier);
    final p = await c.packageInfo;
    final source = await c.sourceDescription();
    if (!mounted) return;
    setState(() {
      _version = 'v${p.version}（build ${p.buildNumber}）';
      _source = source;
    });
  }

  Future<void> _check() async {
    final info = await ref.read(updateControllerProvider.notifier).check();
    if (info != null && mounted) await showUpdateDialog(context, info);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(updateControllerProvider);
    final controller = ref.read(updateControllerProvider.notifier);
    final autoCheck = controller.settings.autoCheck;

    final String status = switch (state) {
      UpdateChecking() => '正在检查…',
      UpdateUpToDate() => '已是最新版本',
      UpdateAvailable(:final info) => '发现新版本 ${info.label}',
      UpdateDownloading(:final info) => '正在下载 ${info.label}…',
      UpdateInstalling(:final info) => '正在安装 ${info.label}',
      UpdateFailed(:final message) => message,
      UpdateIdle() => '',
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(VSpace.contentLeft, VSpace.safeV, VSpace.safeH, 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('设置', style: VText.h1),
          const SizedBox(height: 40),
          Glass(
            width: 1000,
            padding: const EdgeInsets.all(40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('关于与更新', style: VText.rowTitle),
                const SizedBox(height: 24),
                _InfoLine(label: '当前版本', value: _version),
                _InfoLine(label: '更新来源', value: _source),
                const SizedBox(height: 28),
                Row(
                  children: [
                    PillButton(
                      autofocus: true,
                      icon: Icons.refresh_rounded,
                      label: state is UpdateChecking ? '检查中…' : '检查更新',
                      onPressed: state is UpdateChecking ? null : _check,
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      child: Text(
                        status,
                        style: VText.caption.copyWith(
                          color: state is UpdateFailed ? VColors.bad : VColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _Toggle(
                  label: '启动时自动检查更新',
                  value: autoCheck,
                  onChanged: (v) async {
                    await controller.saveSettings(
                      UpdateSettings(autoCheck: v, manifestUrl: controller.settings.manifestUrl),
                    );
                    setState(() {});
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          PillButton(
            label: '片头片尾与前情提要',
            icon: Icons.skip_next_rounded,
            onPressed: () => context.push('/settings/segments'),
          ),
          const SizedBox(height: 32),
          const Text(
            '服务器与线路、反向代理、播放 UA、字幕、元数据等设置会随 M1 起的版本逐步开放。',
            style: TextStyle(fontSize: 20, color: VColors.textTertiary),
          ),
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(
            width: 160,
            child: Text(label, style: VText.label.copyWith(color: VColors.textTertiary)),
          ),
          Expanded(child: Text(value, style: VText.label)),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return VFocusable(
      radius: 18,
      scale: 1.02,
      alignment: Alignment.centerLeft,
      onActivate: () => onChanged(!value),
      builder: (context, focused) => AnimatedContainer(
        duration: VMotion.focus,
        width: 600,
        height: 72,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(
          color: focused ? const Color(0x29FFFFFF) : const Color(0x0DFFFFFF),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Expanded(child: Text(label, style: VText.label)),
            AnimatedContainer(
              duration: VMotion.focus,
              width: 64,
              height: 36,
              padding: const EdgeInsets.all(4),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(
                color: value ? const Color(0xFF5B8CFF) : const Color(0x33FFFFFF),
                borderRadius: BorderRadius.circular(18),
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
