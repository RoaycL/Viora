import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/config/app_config.dart';
import '../../data/config/config_store.dart';
import '../../data/danmaku/danmaku_client.dart';
import '../../data/danmaku/danmaku_models.dart';
import '../../ui/panels/form_dialog.dart';
import '../../ui/widgets/form.dart';
import '../../ui/widgets/toast.dart';

/// 设置 → 弹幕：服务器（最多 3 个，并发搜索）、显示样式、过滤
class DanmakuSettingsSection extends ConsumerWidget {
  const DanmakuSettingsSection({super.key});

  void _update(WidgetRef ref, DanmakuConfig Function(DanmakuConfig) f) =>
      ref.read(configProvider.notifier).update((c) => c.copyWith(danmaku: f(c.danmaku)));

  Future<void> _configureServer(BuildContext context, WidgetRef ref, int index) async {
    final servers = [...ref.read(configProvider).danmaku.servers];
    final controller = TextEditingController(text: index < servers.length ? servers[index] : '');
    await showFormDialog(
      context,
      title: '弹幕服务器 ${index + 1}',
      description:
          '填写自部署的 danmu_api 地址（github.com/huangxd-/danmu_api），格式：https://域名/token，'
          '局域网如 http://192.168.1.10:9321/87654321。留空保存即删除。',
      saveLabel: '保存并测试',
      children: [
        VTextField(
          label: '服务器地址',
          controller: controller,
          autofocus: true,
          hint: 'https://danmu.example.com/87654321',
          keyboardType: TextInputType.url,
        ),
      ],
      onSave: () async {
        final url = DanmakuConfig.normalizeServer(controller.text);
        if (url.isNotEmpty) {
          try {
            await DanmakuClient.test(url);
          } catch (e) {
            showToast('连接失败：$e');
            return false;
          }
        }
        final list = [...ref.read(configProvider).danmaku.servers];
        while (list.length <= index) {
          list.add('');
        }
        list[index] = url;
        while (list.isNotEmpty && list.last.isEmpty) {
          list.removeLast();
        }
        _update(ref, (d) => d.copyWith(servers: list));
        showToast(url.isEmpty ? '已删除弹幕服务器 ${index + 1}' : '弹幕服务器连接成功');
        return true;
      },
    );
    controller.dispose();
  }

  Future<void> _configureBlock(BuildContext context, WidgetRef ref) async {
    final d = ref.read(configProvider).danmaku;
    final words = TextEditingController(text: d.blockWords);
    final search = TextEditingController(text: d.searchBlockWords);
    await showFormDialog(
      context,
      title: '屏蔽词',
      description: '多个关键词用逗号分隔',
      children: [
        VTextField(label: '弹幕内容屏蔽词（包含这些词的弹幕不显示）', controller: words, autofocus: true, hint: '剧透,前方高能'),
        const SizedBox(height: 20),
        VTextField(label: '搜索结果屏蔽词（不想匹配到的版本）', controller: search, hint: '解说,手语,字幕助听'),
      ],
      onSave: () async {
        _update(ref, (x) => x.copyWith(blockWords: words.text.trim(), searchBlockWords: search.text.trim()));
        showToast('屏蔽词已保存');
        return true;
      },
    );
    words.dispose();
    search.dispose();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(configProvider.select((c) => c.danmaku));
    final blocked = splitKeywords(d.blockWords).length + splitKeywords(d.searchBlockWords).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '弹幕来自自部署的 danmu_api（弹弹play 兼容接口，聚合腾讯、爱奇艺、优酷、B 站等）。'
          '播放时按「剧名 + 季 + 集」自动匹配；匹配不对时在播放菜单 → 弹幕里手动选择，同一季后面的集会记住。',
          style: VText.caption.copyWith(color: VColors.textSecondary),
        ),
        const SizedBox(height: 20),
        VToggle(
          label: '播放时显示弹幕',
          subtitle: '关闭后仍可在播放菜单里临时打开',
          value: d.enabled,
          onChanged: (v) => _update(ref, (x) => x.copyWith(enabled: v)),
        ),
        const SizedBox(height: 24),
        Text('弹幕服务器（多个时并发搜索，结果合并）', style: VText.caption.copyWith(color: VColors.textTertiary)),
        const SizedBox(height: 12),
        for (var i = 0; i < DanmakuConfig.maxServers; i++) ...[
          SettingsEntry(
            title: '服务器 ${i + 1}${i == 0 ? '' : '（可选）'}',
            subtitle: i < d.servers.length && d.servers[i].isNotEmpty ? _mask(d.servers[i]) : '未配置',
            status: i < d.servers.length && d.servers[i].isNotEmpty ? '已配置' : null,
            onConfigure: () => _configureServer(context, ref, i),
          ),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 16),
        VChoice<int>(
          label: '每集弹幕数量上限（超出时按全片等比例随机剔除）',
          options: [for (final n in DanmakuConfig.countChoices) (n, n == 0 ? '不限' : '$n')],
          value: d.maxCount,
          onChanged: (v) => _update(ref, (x) => x.copyWith(maxCount: v)),
        ),
        const SizedBox(height: 20),
        VChoice<double>(
          label: '字号',
          options: const [(28.0, '小'), (34.0, '中'), (40.0, '大'), (48.0, '特大')],
          value: d.fontSize,
          onChanged: (v) => _update(ref, (x) => x.copyWith(fontSize: v)),
        ),
        const SizedBox(height: 20),
        VChoice<double>(
          label: '不透明度',
          options: [for (final o in DanmakuConfig.opacityChoices) (o, '${(o * 100).round()}%')],
          value: d.opacity,
          onChanged: (v) => _update(ref, (x) => x.copyWith(opacity: v)),
        ),
        const SizedBox(height: 20),
        VChoice<double>(
          label: '显示区域（滚动弹幕占屏幕的比例）',
          options: const [(0.25, '1/4 屏'), (0.5, '半屏'), (0.75, '3/4 屏'), (1.0, '全屏')],
          value: d.area,
          onChanged: (v) => _update(ref, (x) => x.copyWith(area: v)),
        ),
        const SizedBox(height: 20),
        VChoice<double>(
          label: '滚动速度',
          options: const [(12.0, '慢'), (9.0, '正常'), (6.0, '快')],
          value: d.speed,
          onChanged: (v) => _update(ref, (x) => x.copyWith(speed: v)),
        ),
        const SizedBox(height: 20),
        VToggle(
          label: '显示顶部 / 底部弹幕',
          value: d.showFixed,
          onChanged: (v) => _update(ref, (x) => x.copyWith(showFixed: v)),
        ),
        const SizedBox(height: 20),
        VChoice<DanmakuConvert>(
          label: '繁简转换',
          options: [for (final c in DanmakuConvert.values) (c, c.label)],
          value: d.convert,
          onChanged: (v) => _update(ref, (x) => x.copyWith(convert: v)),
        ),
        const SizedBox(height: 20),
        VChoice<DanmakuColorMode>(
          label: '弹幕颜色',
          options: [for (final c in DanmakuColorMode.values) (c, c.label)],
          value: d.colorMode,
          onChanged: (v) => _update(ref, (x) => x.copyWith(colorMode: v)),
        ),
        const SizedBox(height: 20),
        SettingsEntry(
          title: '屏蔽词',
          subtitle: '弹幕内容屏蔽词、搜索结果屏蔽词',
          status: blocked == 0 ? '未设置' : '$blocked 个',
          onConfigure: () => _configureBlock(context, ref),
        ),
      ],
    );
  }

  /// 地址里的 token 只显示前后几位
  static String _mask(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.pathSegments.isEmpty) return url;
    final token = u.pathSegments.last;
    final masked = token.length <= 6 ? '••••' : '${token.substring(0, 2)}••••${token.substring(token.length - 2)}';
    return '${u.scheme}://${u.authority}/${[...u.pathSegments.take(u.pathSegments.length - 1), masked].join('/')}';
  }
}
