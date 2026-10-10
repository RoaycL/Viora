import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/segments/segment_http.dart';
import '../../domain/models/segment.dart';
import '../../domain/models/segment_settings.dart';
import '../../domain/usecases/segment_resolver.dart';
import '../../ui/glass/glass.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/toast.dart';
import 'segment_service.dart';

const _providerNames = {'theintrodb': 'TheIntroDB', 'introdb': 'IntroDB', 'publicmetadb': 'PublicMetaDB'};
const _typeNames = {
  SegmentType.intro: '片头',
  SegmentType.recap: '前情提要',
  SegmentType.credits: '片尾',
  SegmentType.preview: '下集预告',
};

class SegmentSettingsPage extends ConsumerStatefulWidget {
  const SegmentSettingsPage({super.key});
  @override
  ConsumerState<SegmentSettingsPage> createState() => _SegmentSettingsPageState();
}

class _SegmentSettingsPageState extends ConsumerState<SegmentSettingsPage> {
  bool _saving = false;
  bool _querying = false;
  int _lookupGeneration = 0;
  SegmentResolution? _result;

  Future<void> _save(SegmentSettings settings) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await ref.read(segmentSettingsProvider.notifier).save(settings);
      _lookupGeneration++;
      if (mounted) setState(() => _result = null);
    } on Exception {
      showToast('设置保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _configure(SegmentSettings settings, int index) async {
    final config = settings.providers[index];
    final url = TextEditingController(text: config.baseUrl);
    final key = TextEditingController(text: config.apiKey);
    final form = GlobalKey<FormState>();
    final route = DialogRoute<SegmentProviderSettings>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_providerNames[config.id]!),
        content: SizedBox(
          width: 700,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: url,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'API 地址'),
                  validator: (text) {
                    try {
                      segmentEndpoint(Uri.parse(text!.trim()), 'check', {});
                      return null;
                    } on FormatException {
                      return '请填写不含账号密码、查询参数的 HTTPS 地址';
                    }
                  },
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: key,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: config.id == 'publicmetadb' ? 'API Key（必填）' : 'API Key（可选，留空公开读取）',
                  ),
                  validator: (text) => config.id == 'publicmetadb' && (text == null || text.trim().isEmpty)
                      ? '请在 PublicMetaDB 设置 → API 中生成 Key'
                      : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(context, config.copyWith(baseUrl: url.text.trim(), apiKey: key.text.trim()));
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final updated = await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    url.dispose();
    key.dispose();
    if (updated != null && mounted) {
      final providers = [...settings.providers]..[index] = updated;
      await _save(settings.copyWith(providers: providers));
    }
  }

  Future<void> _lookup() async {
    final tmdb = TextEditingController();
    final imdb = TextEditingController();
    final season = TextEditingController(text: '1');
    final episode = TextEditingController(text: '1');
    final duration = TextEditingController();
    var movie = false;
    final form = GlobalKey<FormState>();
    final route = DialogRoute<SegmentQuery>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('查询跳过片段'),
          content: SizedBox(
            width: 700,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SwitchListTile(title: const Text('电影'), value: movie, onChanged: (v) => update(() => movie = v)),
                    TextFormField(
                      controller: tmdb,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: movie ? '电影 TMDB ID' : '剧集 TMDB ID（整部剧）'),
                      validator: (v) => v!.isNotEmpty && (int.tryParse(v) ?? 0) <= 0 ? '请输入有效的 TMDB ID' : null,
                    ),
                    TextFormField(
                      controller: imdb,
                      decoration: const InputDecoration(labelText: 'IMDb ID（tt 开头，IntroDB 必需）'),
                      validator: (v) {
                        if (v!.isEmpty && tmdb.text.isEmpty) {
                          return '至少填写一个作品 ID';
                        }
                        return v.isNotEmpty && !RegExp(r'^tt\d+$').hasMatch(v) ? '格式示例：tt0903747' : null;
                      },
                    ),
                    if (!movie)
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: season,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(labelText: '季'),
                              validator: (v) => (int.tryParse(v ?? '') ?? -1) < 0 ? '请输入季号' : null,
                            ),
                          ),
                          const SizedBox(width: 24),
                          Expanded(
                            child: TextFormField(
                              controller: episode,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(labelText: '集'),
                              validator: (v) => (int.tryParse(v ?? '') ?? 0) <= 0 ? '请输入集号' : null,
                            ),
                          ),
                        ],
                      ),
                    TextFormField(
                      controller: duration,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '实际文件时长（秒）'),
                      validator: (v) {
                        final value = double.tryParse(v ?? '');
                        return value == null || !value.isFinite || value <= 0 ? '请输入实际文件时长' : null;
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            TextButton(
              onPressed: () {
                if (!form.currentState!.validate()) return;
                Navigator.pop(
                  context,
                  SegmentQuery(
                    titleKey: tmdb.text.isEmpty ? 'imdb:${imdb.text}' : 'tmdb:${movie ? 'movie' : 'tv'}:${tmdb.text}',
                    kind: movie ? SegmentMediaKind.movie : SegmentMediaKind.episode,
                    tmdbId: int.tryParse(tmdb.text),
                    imdbId: imdb.text.isEmpty ? null : imdb.text,
                    season: movie ? null : int.parse(season.text),
                    episode: movie ? null : int.parse(episode.text),
                    duration: Duration(milliseconds: (double.parse(duration.text) * 1000).round()),
                  ),
                );
              },
              child: const Text('查询'),
            ),
          ],
        ),
      ),
    );
    final query = await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    for (final c in [tmdb, imdb, season, episode, duration]) {
      c.dispose();
    }
    if (query == null || !mounted) return;
    final generation = ++_lookupGeneration;
    setState(() {
      _querying = true;
      _result = null;
    });
    try {
      final resolver = await ref.read(segmentResolverProvider.future);
      final result = await resolver.resolve(query);
      if (mounted && generation == _lookupGeneration) setState(() => _result = result);
    } on Exception {
      showToast('片段查询失败，请检查来源配置');
    } finally {
      if (mounted) setState(() => _querying = false);
    }
  }

  @override
  Widget build(BuildContext context) => ref
      .watch(segmentSettingsProvider)
      .when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: PillButton(
            label: '设置读取失败 · 重试',
            autofocus: true,
            onPressed: () => ref.invalidate(segmentSettingsProvider),
          ),
        ),
        data: (settings) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(VSpace.contentLeft, VSpace.safeV, VSpace.safeH, 120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('片头片尾与前情提要', style: VText.h1),
              const SizedBox(height: 32),
              Glass(
                width: 1200,
                padding: const EdgeInsets.all(32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('跳过方式', style: VText.rowTitle),
                    const SizedBox(height: 20),
                    _mode('片头', settings.intro, (m) => _save(settings.copyWith(intro: m))),
                    _mode('前情提要', settings.recap, (m) => _save(settings.copyWith(recap: m))),
                    _mode('片尾', settings.credits, (m) => _save(settings.copyWith(credits: m)), credits: true),
                    PillButton(
                      label: '每部剧首集保留片头：${settings.firstEpisodeException ? '开启' : '关闭'}',
                      onPressed: _saving
                          ? null
                          : () => _save(settings.copyWith(firstEpisodeException: !settings.firstEpisodeException)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              Glass(
                width: 1200,
                padding: const EdgeInsets.all(32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('片段数据来源', style: VText.rowTitle),
                    const SizedBox(height: 12),
                    const Text('按顺序优先使用有效数据；缺失的片段类型由后续来源补全。', style: VText.caption),
                    const SizedBox(height: 24),
                    for (var index = 0; index < settings.providers.length; index++) _provider(settings, index),
                    const Text('IntroDB 的片段数据由 introdb.app 提供。PublicMetaDB 需填写 API Key，提供片头和片尾。', style: VText.caption),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              PillButton(
                label: _querying ? '查询中…' : '查询跳过片段',
                icon: Icons.search_rounded,
                onPressed: _querying || _saving ? null : _lookup,
              ),
              if (_result != null) ...[
                const SizedBox(height: 24),
                if (_result!.segments.isEmpty) const Text('没有找到通过时长校验的片段，请确认作品 ID、季集号与文件时长。', style: VText.caption),
                for (final s in _result!.segments)
                  Text(
                    '${_typeNames[s.type]}  ${_clock(s.start)} → ${_clock(s.end)}  ·  ${_providerNames[s.provider] ?? s.provider}',
                    style: VText.label,
                  ),
                for (final e in _result!.failures.entries)
                  Text('${_providerNames[e.key]}：${_failure(e.value)}', style: VText.caption),
              ],
            ],
          ),
        ),
      );

  Widget _mode(String label, SegmentSkipMode value, ValueChanged<SegmentSkipMode> update, {bool credits = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Row(
          children: [
            SizedBox(width: 200, child: Text(label, style: VText.label)),
            PillButton(
              label: switch (value) {
                SegmentSkipMode.auto => credits ? '自动下一集 / 跳过片尾' : '自动跳过',
                SegmentSkipMode.button => '显示按钮',
                SegmentSkipMode.off => '关闭',
              },
              onPressed: _saving
                  ? null
                  : () => update(SegmentSkipMode.values[(value.index + 1) % SegmentSkipMode.values.length]),
            ),
          ],
        ),
      );

  Widget _provider(SegmentSettings settings, int index) {
    final config = settings.providers[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${index + 1}. ${_providerNames[config.id]}', style: VText.label),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 12,
            children: [
              PillButton(
                label: config.enabled ? '已开启' : '已关闭',
                onPressed: _saving
                    ? null
                    : () {
                        if (!config.enabled && config.id == 'publicmetadb' && config.apiKey.isEmpty) {
                          showToast('请先配置 PublicMetaDB API Key');
                          return;
                        }
                        final providers = [...settings.providers]..[index] = config.copyWith(enabled: !config.enabled);
                        _save(settings.copyWith(providers: providers));
                      },
              ),
              PillButton(
                label: '配置',
                icon: Icons.tune_rounded,
                onPressed: _saving ? null : () => _configure(settings, index),
              ),
              if (index > 0)
                PillButton(
                  label: '提高优先级',
                  icon: Icons.arrow_upward_rounded,
                  onPressed: _saving
                      ? null
                      : () {
                          final providers = [...settings.providers];
                          providers[index] = providers[index - 1];
                          providers[index - 1] = config;
                          _save(settings.copyWith(providers: providers));
                        },
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _clock(Duration value) => '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
  String _failure(SegmentFailure failure) => switch (failure) {
    SegmentFailure.timeout => '请求超时',
    SegmentFailure.unauthorized => '请检查 API Key',
    SegmentFailure.rateLimited => '请求次数已达上限，请稍后重试',
    SegmentFailure.unavailable => '暂时无法连接',
    SegmentFailure.invalidResponse => '返回数据格式不兼容',
  };
}
