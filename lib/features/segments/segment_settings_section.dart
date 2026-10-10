import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/segments/segment_http.dart';
import '../../domain/models/segment_settings.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/form.dart';
import '../../ui/widgets/toast.dart';
import 'segment_service.dart';

const _circled = ['①', '②', '③', '④', '⑤', '⑥'];

const _providerInfo = {
  'theintrodb': ('TheIntroDB', '按 TMDB ID（没有时用 IMDb ID）查询；片头、前情提要、片尾、预告。公开读取，Key 可选'),
  'introdb': ('IntroDB', '按 IMDb ID 查询；片头、前情提要、片尾，会避开片尾彩蛋。公开读取，Key 可选'),
  'publicmetadb': ('PublicMetaDB', '按 TMDB ID 查询；片头、片尾。必须填写 API Key（PublicMetaDB 设置 → API）'),
};

/// 设置 → 片头片尾（docs/05-metadata-and-segments.md §3）：跳过方式、数据来源与优先级、API Key。
class SegmentSettingsSection extends ConsumerStatefulWidget {
  const SegmentSettingsSection({super.key});

  @override
  ConsumerState<SegmentSettingsSection> createState() => _SegmentSettingsSectionState();
}

class _SegmentSettingsSectionState extends ConsumerState<SegmentSettingsSection> {
  final _keys = <String, TextEditingController>{};
  final _urls = <String, TextEditingController>{};
  bool _loaded = false;

  @override
  void dispose() {
    for (final c in [..._keys.values, ..._urls.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(SegmentSettings s) {
    if (_loaded) return;
    _loaded = true;
    for (final p in s.providers) {
      _keys[p.id] = TextEditingController(text: p.apiKey);
      _urls[p.id] = TextEditingController(text: p.baseUrl);
    }
  }

  Future<void> _save(SegmentSettings s, {String? done}) async {
    try {
      await ref.read(segmentSettingsProvider.notifier).save(s);
      if (done != null) showToast(done);
    } catch (e) {
      showToast('保存失败：$e');
    }
  }

  Future<void> _saveSources(SegmentSettings s) async {
    final providers = <SegmentProviderSettings>[];
    for (final p in s.providers) {
      final url = _urls[p.id]!.text.trim().isEmpty ? segmentProviderDefaults[p.id]! : _urls[p.id]!.text.trim();
      try {
        segmentEndpoint(Uri.parse(url), 'check', const {});
      } on FormatException {
        showToast('${_providerInfo[p.id]!.$1} 的 API 地址需要是 https:// 开头、不带账号密码和参数的地址');
        return;
      }
      final key = _keys[p.id]!.text.trim();
      // PublicMetaDB 没有 Key 时不能启用
      providers.add(
        p.copyWith(baseUrl: url, apiKey: key, enabled: p.id == 'publicmetadb' && key.isEmpty ? false : p.enabled),
      );
    }
    await _save(s.copyWith(providers: providers), done: 'API 设置已保存');
  }

  void _move(SegmentSettings s, int i, int delta) {
    final j = i + delta;
    if (j < 0 || j >= s.providers.length) return;
    final list = [...s.providers];
    final p = list.removeAt(i);
    list.insert(j, p);
    _save(s.copyWith(providers: list));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(segmentSettingsProvider);
    final s = async.value;
    if (s == null) {
      return Text(async.hasError ? '读取设置失败：${async.error}' : '加载中…', style: VText.label);
    }
    _fill(s);
    const modes = [(SegmentSkipMode.auto, '自动跳过'), (SegmentSkipMode.button, '显示按钮'), (SegmentSkipMode.off, '关闭')];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '播放时出现「跳过片头」「下一集」按钮，电视上按 OK、电脑上按回车或点击即可跳过。数据按下面的优先级取第一个有效的来源。',
          style: VText.caption.copyWith(color: VColors.textSecondary),
        ),
        const SizedBox(height: 24),
        VChoice<SegmentSkipMode>(
          label: '片头',
          options: modes,
          value: s.intro,
          onChanged: (v) => _save(s.copyWith(intro: v)),
        ),
        const SizedBox(height: 20),
        VChoice<SegmentSkipMode>(
          label: '前情提要',
          options: modes,
          value: s.recap,
          onChanged: (v) => _save(s.copyWith(recap: v)),
        ),
        const SizedBox(height: 20),
        VChoice<SegmentSkipMode>(
          label: '片尾（有下一集且片尾直到结尾时播放下一集，否则跳到片尾结束处）',
          options: const [
            (SegmentSkipMode.auto, '自动下一集'),
            (SegmentSkipMode.button, '显示按钮'),
            (SegmentSkipMode.off, '关闭'),
          ],
          value: s.credits,
          onChanged: (v) => _save(s.copyWith(credits: v)),
        ),
        const SizedBox(height: 20),
        VToggle(
          label: '每部剧第一集不自动跳过片头',
          subtitle: '第 1 季第 1 集只显示按钮，第一次看可以完整欣赏片头',
          value: s.firstEpisodeException,
          onChanged: (v) => _save(s.copyWith(firstEpisodeException: v)),
        ),
        const SizedBox(height: 36),
        Text('数据来源（从上到下优先）', style: VText.rowTitle.copyWith(fontSize: 26)),
        const SizedBox(height: 16),
        VToggle(
          label: '① 媒体服务器标记',
          subtitle: 'Emby 4.8+ 的章节标记、Jellyfin 10.10+ 的媒体片段（含 Intro Skipper 插件）。最准确，始终最优先',
          value: s.serverMarkers,
          onChanged: (v) => _save(s.copyWith(serverMarkers: v)),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < s.providers.length; i++) ...[
          _ProviderCard(
            index: i + 2,
            settings: s.providers[i],
            keyController: _keys[s.providers[i].id]!,
            urlController: _urls[s.providers[i].id]!,
            canUp: i > 0,
            canDown: i < s.providers.length - 1,
            onUp: () => _move(s, i, -1),
            onDown: () => _move(s, i, 1),
            onToggle: (v) {
              if (v && s.providers[i].id == 'publicmetadb' && _keys['publicmetadb']!.text.trim().isEmpty) {
                showToast('PublicMetaDB 需要先填写 API Key 并保存');
                return;
              }
              final list = [...s.providers]..[i] = s.providers[i].copyWith(enabled: v);
              _save(s.copyWith(providers: list));
            },
          ),
          const SizedBox(height: 12),
        ],
        VToggle(
          label: '${_circled[s.providers.length + 1]} 章节名识别（兜底）',
          subtitle: '以上都没有数据时，把名为 OP / Opening / 片头、ED / Ending / 片尾 的章节当作片头片尾',
          value: s.chapterNames,
          onChanged: (v) => _save(s.copyWith(chapterNames: v)),
        ),
        const SizedBox(height: 24),
        VToggle(
          label: '第三方数据库通过反向代理访问',
          subtitle: '国内直连不稳定时打开（使用「反向代理」里填写的地址）',
          value: s.useProxy,
          onChanged: (v) => _save(s.copyWith(useProxy: v)),
        ),
        const SizedBox(height: 24),
        PillButton(icon: Icons.save_rounded, label: '保存 API Key 与地址', onPressed: () => _saveSources(s)),
        const SizedBox(height: 12),
        Text(
          'API Key 保存在系统安全存储中（Windows 凭据管理器 / Android Keystore），不写入普通配置文件。',
          style: VText.small.copyWith(color: VColors.textTertiary),
        ),
      ],
    );
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.index,
    required this.settings,
    required this.keyController,
    required this.urlController,
    required this.canUp,
    required this.canDown,
    required this.onUp,
    required this.onDown,
    required this.onToggle,
  });

  final int index;
  final SegmentProviderSettings settings;
  final TextEditingController keyController;
  final TextEditingController urlController;
  final bool canUp;
  final bool canDown;
  final VoidCallback onUp;
  final VoidCallback onDown;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final (name, desc) = _providerInfo[settings.id]!;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: const Color(0x0AFFFFFF), borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: VToggle(
                  label: '${_circled[(index - 1).clamp(0, 5)]} $name',
                  subtitle: desc,
                  value: settings.enabled,
                  onChanged: onToggle,
                ),
              ),
              const SizedBox(width: 16),
              PillButton(icon: Icons.arrow_upward_rounded, label: '上移', onPressed: canUp ? onUp : null),
              const SizedBox(width: 12),
              PillButton(icon: Icons.arrow_downward_rounded, label: '下移', onPressed: canDown ? onDown : null),
            ],
          ),
          if (settings.enabled || settings.id == 'publicmetadb') ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: VTextField(
                    label: settings.id == 'publicmetadb' ? 'API Key（必填）' : 'API Key（可选）',
                    controller: keyController,
                    obscure: true,
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: VTextField(
                    label: 'API 地址（可改为自建反代）',
                    controller: urlController,
                    hint: segmentProviderDefaults[settings.id],
                    keyboardType: TextInputType.url,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
