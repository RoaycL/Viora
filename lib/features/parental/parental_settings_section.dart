import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/config/app_config.dart';
import '../../data/config/config_store.dart';
import '../../ui/panels/form_dialog.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/form.dart';
import '../../ui/widgets/toast.dart';

/// PIN 的哈希（加上设备 ID，不同设备上同样的 PIN 哈希不同）
String hashPin(String pin, String deviceId) => sha256.convert(utf8.encode('viora-parental:$deviceId:$pin')).toString();

/// 设置 → 家长控制（docs/12-parental.md）
class ParentalSettingsSection extends ConsumerWidget {
  const ParentalSettingsSection({super.key});

  Future<void> _enable(BuildContext context, WidgetRef ref) async {
    final pin = TextEditingController();
    final again = TextEditingController();
    await showFormDialog(
      context,
      title: '设置家长 PIN',
      description: '关闭儿童模式时需要输入这 4 位数字。请记住它：忘记后只能清除应用数据重新设置。',
      saveLabel: '开启儿童模式',
      children: [
        VTextField(
          label: 'PIN（4 位数字）',
          controller: pin,
          obscure: true,
          autofocus: true,
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 20),
        VTextField(label: '再输入一次', controller: again, obscure: true, keyboardType: TextInputType.number),
      ],
      onSave: () async {
        final p = pin.text.trim();
        if (!RegExp(r'^\d{4}$').hasMatch(p)) {
          showToast('PIN 需要是 4 位数字');
          return false;
        }
        if (p != again.text.trim()) {
          showToast('两次输入的 PIN 不一样');
          return false;
        }
        await ref
            .read(configProvider.notifier)
            .update((c) => c.copyWith(parental: c.parental.copyWith(enabled: true, pinHash: hashPin(p, c.deviceId))));
        showToast('儿童模式已开启');
        return true;
      },
    );
    pin.dispose();
    again.dispose();
  }

  Future<void> _disable(BuildContext context, WidgetRef ref) async {
    final pin = TextEditingController();
    var failures = 0;
    await showFormDialog(
      context,
      title: '关闭儿童模式',
      description: '输入家长 PIN',
      saveLabel: '关闭',
      children: [
        VTextField(label: 'PIN', controller: pin, obscure: true, autofocus: true, keyboardType: TextInputType.number),
      ],
      onSave: () async {
        final c = ref.read(configProvider);
        if (hashPin(pin.text.trim(), c.deviceId) != c.parental.pinHash) {
          failures++;
          pin.clear();
          showToast(failures >= 3 ? 'PIN 不对（已输错 $failures 次）' : 'PIN 不对');
          // 连续输错时稍等一下，防止乱按试出来
          if (failures >= 3) await Future<void>.delayed(Duration(seconds: failures * 2));
          return false;
        }
        await ref
            .read(configProvider.notifier)
            .update((c) => c.copyWith(parental: c.parental.copyWith(enabled: false)));
        showToast('儿童模式已关闭');
        return true;
      },
    );
    pin.dispose();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(configProvider.select((c) => c.parental));
    final hidden = ref.watch(configProvider.select((c) => c.allServers.where((s) => s.adult).length));
    void update(ParentalConfig Function(ParentalConfig) f) =>
        ref.read(configProvider.notifier).update((c) => c.copyWith(parental: f(c.parental)));
    final age = ParentalConfig.ageOptions.where((o) => o.$1 == p.maxAge).firstOrNull?.$2 ?? '${p.maxAge} 岁以下';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '儿童模式下：隐藏标记了「R18」的服务器；按年龄分级过滤影片（服务器按分级过滤，Viora 再检查一遍）；'
          '首页推荐换成适合儿童的动画和家庭影片。关闭儿童模式需要家长 PIN。',
          style: VText.caption.copyWith(color: VColors.textSecondary),
        ),
        const SizedBox(height: 24),
        if (p.enabled) ...[
          Row(
            children: [
              const Icon(Icons.child_care_rounded, color: Color(0xFF7BE07B), size: 32),
              const SizedBox(width: 12),
              Text('儿童模式已开启 · $age', style: VText.label.copyWith(fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 20),
          PillButton(icon: Icons.lock_open_rounded, label: '关闭儿童模式', onPressed: () => _disable(context, ref)),
        ] else ...[
          VChoice<int>(
            label: '年龄分级',
            options: ParentalConfig.ageOptions,
            value: p.maxAge,
            onChanged: (v) => update((x) => x.copyWith(maxAge: v)),
          ),
          const SizedBox(height: 16),
          VToggle(
            label: '隐藏没有分级的内容',
            subtitle: '国内资源很多没有分级信息，打开后可能隐藏大量内容',
            value: p.blockUnrated,
            onChanged: (v) => update((x) => x.copyWith(blockUnrated: v)),
          ),
          const SizedBox(height: 24),
          PillButton(icon: Icons.child_care_rounded, label: '开启儿童模式', onPressed: () => _enable(context, ref)),
        ],
        const SizedBox(height: 20),
        Text(
          hidden == 0 ? '提示：在「资源库 → 编辑服务器」里勾选 R18 的服务器，儿童模式下会整个隐藏。' : '已标记 R18 的服务器 $hidden 台，儿童模式下整个隐藏。',
          style: VText.small.copyWith(color: VColors.textTertiary),
        ),
      ],
    );
  }
}
