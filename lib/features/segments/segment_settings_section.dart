import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/segments/segment_http.dart';
import '../../domain/models/segment_settings.dart';
import '../../player/manual_segments.dart';
import '../../ui/panels/form_dialog.dart';
import '../../ui/widgets/form.dart';
import '../../ui/widgets/toast.dart';
import 'segment_service.dart';

const _circled = ['①', '②', '③', '④', '⑤', '⑥'];

const _providerInfo = {
  'theintrodb': ('TheIntroDB', '按 TMDB ID（没有时用 IMDb ID）查询；片头、前情提要、片尾、预告。公开读取，Key 可选'),
  'introdb': ('IntroDB', '按 IMDb ID 查询；片头、前情提要、片尾，会避开片尾彩蛋。公开读取，Key 可选'),
  'publicmetadb': ('PublicMetaDB', '按 TMDB ID 查询；片头、片尾。必须填写 API Key（PublicMetaDB 设置 → API）'),
};

/// 设置 → 片头片尾（docs/05-metadata-and-segments.md §3）：跳过方式、数据来源与优先级。
/// [apiSources] 为 true 时只显示第三方数据库（API Key、地址、排序、反代），放在「设置 → 接口与网络」。
class SegmentSettingsSection extends ConsumerStatefulWidget {
  const SegmentSettingsSection({super.key, this.apiSources = false});

  final bool apiSources;

  @override
  ConsumerState<SegmentSettingsSection> createState() => _SegmentSettingsSectionState();
}

class _SegmentSettingsSectionState extends ConsumerState<SegmentSettingsSection> {
  Future<int> _manualCount = ManualSegmentStore.count();

  /// 返回是否保存成功（失败时弹窗不关闭，保留已输入的内容）
  Future<bool> _save(SegmentSettings s, {String? done}) async {
    try {
      await ref.read(segmentSettingsProvider.notifier).save(s);
      if (done != null) showToast(done);
      return true;
    } catch (e) {
      showToast('保存失败：$e');
      return false;
    }
  }

  /// 某个数据源的 API Key 与地址（弹窗设置）
  Future<void> _configure(SegmentSettings s, int i) async {
    final p = s.providers[i];
    final (name, _) = _providerInfo[p.id]!;
    final key = TextEditingController(text: p.apiKey);
    final url = TextEditingController(text: p.baseUrl);
    await showFormDialog(
      context,
      title: name,
      description: p.id == 'publicmetadb'
          ? '必须填写 API Key：在 PublicMetaDB 网站的「设置 → API」里生成。'
          : '公开读取不需要 Key；有 Key 时可获得更高的请求额度。',
      children: [
        VTextField(
          label: p.id == 'publicmetadb' ? 'API Key（必填）' : 'API Key（可选）',
          controller: key,
          obscure: true,
          autofocus: true,
        ),
        const SizedBox(height: 20),
        VTextField(
          label: 'API 地址（可改为自建反代，留空恢复默认）',
          controller: url,
          hint: segmentProviderDefaults[p.id],
          keyboardType: TextInputType.url,
        ),
      ],
      onSave: () async {
        final u = url.text.trim().isEmpty ? segmentProviderDefaults[p.id]! : url.text.trim();
        try {
          segmentEndpoint(Uri.parse(u), 'check', const {});
        } on FormatException {
          showToast('API 地址需要是 https:// 开头、不带账号密码和参数的地址');
          return false;
        }
        final k = key.text.trim();
        final list = [...s.providers]
          ..[i] = p.copyWith(
            baseUrl: u,
            apiKey: k,
            // PublicMetaDB 没有 Key 时不能启用；刚填上 Key 时自动启用
            enabled: p.id == 'publicmetadb' ? k.isNotEmpty && (p.enabled || p.apiKey.isEmpty) : p.enabled,
          );
        return _save(s.copyWith(providers: list), done: '$name 已保存');
      },
    );
    key.dispose();
    url.dispose();
  }

  void _move(SegmentSettings s, int i, int delta) {
    final j = i + delta;
    if (j < 0 || j >= s.providers.length) return;
    final list = [...s.providers];
    final p = list.removeAt(i);
    list.insert(j, p);
    _save(s.copyWith(providers: list));
  }

  Widget _providerEntry(SegmentSettings s, int i) {
    final p = s.providers[i];
    final (name, desc) = _providerInfo[p.id]!;
    return SettingsEntry(
      title: '${_circled[i]} $name',
      subtitle: desc,
      status: p.apiKey.isNotEmpty ? '已填写 Key' : (p.id == 'publicmetadb' ? '未填写 Key' : null),
      trailing: [
        SmallIconButton(
          icon: Icons.arrow_upward_rounded,
          semanticLabel: '上移 $name',
          onPressed: i > 0 ? () => _move(s, i, -1) : null,
        ),
        SmallIconButton(
          icon: Icons.arrow_downward_rounded,
          semanticLabel: '下移 $name',
          onPressed: i < s.providers.length - 1 ? () => _move(s, i, 1) : null,
        ),
        SmallSwitch(
          label: name,
          value: p.enabled,
          onChanged: (v) {
            if (v && p.id == 'publicmetadb' && p.apiKey.isEmpty) {
              showToast('PublicMetaDB 需要先点「设置」填写 API Key');
              return;
            }
            final list = [...s.providers]..[i] = p.copyWith(enabled: v);
            _save(s.copyWith(providers: list));
          },
        ),
      ],
      onConfigure: () => _configure(s, i),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(segmentSettingsProvider);
    final s = async.value;
    if (s == null) {
      return Text(async.hasError ? '读取设置失败：${async.error}' : '加载中…', style: VText.label);
    }
    if (widget.apiSources) return _apiSources(s);
    const modes = [(SegmentSkipMode.auto, '自动跳过'), (SegmentSkipMode.button, '显示按钮'), (SegmentSkipMode.off, '关闭')];
    final enabled = [
      for (final p in s.providers)
        if (p.enabled) _providerInfo[p.id]!.$1,
    ];
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
        FutureBuilder<int>(
          future: _manualCount,
          builder: (context, snap) => SettingsEntry(
            title: '⓪ 手动标记（最优先）',
            subtitle: (snap.data ?? 0) == 0
                ? '播放时在菜单 →「片头片尾标记」里以当前位置标记片头 / 片尾，剧集同一季各集通用'
                : '已标记 ${snap.data} 部剧 / 电影。播放时在菜单 →「片头片尾标记」里修改或清除',
            trailing: [
              if ((snap.data ?? 0) > 0)
                SmallIconButton(
                  icon: Icons.delete_outline_rounded,
                  label: '全部清除',
                  onPressed: () async {
                    await ManualSegmentStore.clearAll();
                    showToast('已清除所有手动标记');
                    setState(() => _manualCount = ManualSegmentStore.count());
                  },
                ),
            ],
            onConfigure: () => showToast('在播放时打开菜单 →「片头片尾标记」，以当前播放位置标记'),
          ),
        ),
        const SizedBox(height: 12),
        VToggle(
          label: '① 媒体服务器标记',
          subtitle: 'Emby 4.8+ 的章节标记、Jellyfin 10.10+ 的媒体片段（含 Intro Skipper 插件）。最准确，始终最优先',
          value: s.serverMarkers,
          onChanged: (v) => _save(s.copyWith(serverMarkers: v)),
        ),
        const SizedBox(height: 12),
        // 第三方数据库的 Key、地址、排序在「接口与网络」里统一管理，这里只说明当前启用了哪些
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Text(
            '② 第三方数据库：${enabled.isEmpty ? '未启用' : enabled.join(' → ')}'
            '（在「设置 → 接口与网络」里填写 Key、调整顺序）',
            style: VText.caption.copyWith(color: VColors.textSecondary),
          ),
        ),
        const SizedBox(height: 12),
        VToggle(
          label: '③ 章节名识别（兜底）',
          subtitle: '以上都没有数据时，把名为 OP / Opening / 片头、ED / Ending / 片尾 的章节当作片头片尾',
          value: s.chapterNames,
          onChanged: (v) => _save(s.copyWith(chapterNames: v)),
        ),
      ],
    );
  }

  /// 「接口与网络」里的第三方片头片尾数据库
  Widget _apiSources(SegmentSettings s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('媒体服务器没有片头片尾标记时，按下面的顺序查询（取第一个有数据的）。', style: VText.caption.copyWith(color: VColors.textSecondary)),
        const SizedBox(height: 16),
        for (var i = 0; i < s.providers.length; i++) ...[_providerEntry(s, i), const SizedBox(height: 12)],
        VToggle(
          label: '通过反向代理访问',
          subtitle: '国内直连不稳定时打开（使用上面填写的反向代理地址）',
          value: s.useProxy,
          onChanged: (v) => _save(s.copyWith(useProxy: v)),
        ),
        const SizedBox(height: 12),
        Text(
          'API Key 保存在系统安全存储中（Windows 凭据管理器 / Android Keystore），不写入普通配置文件。',
          style: VText.small.copyWith(color: VColors.textTertiary),
        ),
      ],
    );
  }
}
