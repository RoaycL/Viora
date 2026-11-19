import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/config/app_config.dart';
import '../../data/config/config_store.dart';
import '../../data/subtitles/online_subtitles.dart';
import '../../ui/panels/form_dialog.dart';
import '../../ui/widgets/form.dart';
import '../../ui/widgets/toast.dart';

/// 设置 → 接口与网络 → 在线字幕：播放页「在线搜索字幕」除了媒体服务器，还会查这里的来源
class OnlineSubtitleSettingsSection extends ConsumerWidget {
  const OnlineSubtitleSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(configProvider).subtitles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '播放时「字幕 → 在线搜索字幕」会同时查媒体服务器的字幕插件和下面的来源，下载后直接在本机加载，不写入服务器。',
          style: VText.caption.copyWith(color: VColors.textSecondary),
        ),
        const SizedBox(height: 20),
        SettingsEntry(
          title: '射手网（伪）',
          subtitle: '中文字幕最全；需要自己的 token（assrt.net 注册后在用户中心领取）',
          status: c.assrtEnabled ? '已填写 token' : '未填写',
          onConfigure: () => _configureAssrt(context, ref),
        ),
        const SizedBox(height: 12),
        SettingsEntry(
          title: 'OpenSubtitles',
          subtitle: '英文等外语字幕最全；不登录每天约 5 次下载，登录自己的账号后更多',
          status: !c.openSubtitlesEnabled
              ? '此版本未内置 Key'
              : c.osLoggedIn
              ? '已登录 ${c.osUsername.trim()}'
              : '匿名使用',
          onConfigure: () => _configureOpenSubtitles(context, ref),
        ),
      ],
    );
  }

  Future<void> _configureAssrt(BuildContext context, WidgetRef ref) async {
    final token = TextEditingController(text: ref.read(configProvider).subtitles.assrtToken);
    await showFormDialog(
      context,
      title: '射手网（伪）',
      description: '在 assrt.net 注册登录后，到用户中心复制 32 位的 API token。留空保存即停用。',
      saveLabel: '保存并测试',
      children: [VTextField(label: 'API token', controller: token, obscure: true, autofocus: true)],
      onSave: () async {
        final value = token.text.trim();
        await ref
            .read(configProvider.notifier)
            .update((c) => c.copyWith(subtitles: c.subtitles.copyWith(assrtToken: value)));
        if (value.isEmpty) {
          showToast('已停用射手网（伪）');
          return true;
        }
        try {
          final quota = await AssrtClient(value).quota();
          showToast(quota == null ? '射手网（伪）连接成功' : '射手网（伪）连接成功：每分钟可请求 $quota 次');
        } catch (e) {
          showToast('$e');
        }
        return true;
      },
    );
  }

  Future<void> _configureOpenSubtitles(BuildContext context, WidgetRef ref) async {
    final c = ref.read(configProvider).subtitles;
    final user = TextEditingController(text: c.osUsername);
    final password = TextEditingController(text: c.osPassword);
    await showFormDialog(
      context,
      title: 'OpenSubtitles 账号（可选）',
      description: SubtitleSourcesConfig.builtinOpenSubtitlesKey.isEmpty
          ? '这个版本没有内置 OpenSubtitles 的 API Key，暂时不能使用（正式发布的版本内置）。'
          : '不登录也能用，但每天只能下载约 5 次。在 opensubtitles.com 免费注册后填在这里，下载次数更多。用户名和密码都留空即退出登录。',
      saveLabel: '保存并测试',
      children: [
        VTextField(label: '用户名（不是邮箱）', controller: user, autofocus: true),
        const SizedBox(height: 20),
        VTextField(label: '密码', controller: password, obscure: true),
      ],
      onSave: () async {
        final next = c.copyWith(osUsername: user.text.trim(), osPassword: password.text);
        await ref.read(configProvider.notifier).update((x) => x.copyWith(subtitles: next));
        if (!next.osLoggedIn) {
          showToast('OpenSubtitles 将匿名使用');
          return true;
        }
        if (!next.openSubtitlesEnabled) return true;
        try {
          await OpenSubtitlesClient(next).testLogin();
          showToast('OpenSubtitles 登录成功');
        } catch (e) {
          showToast('$e');
        }
        return true;
      },
    );
  }
}
