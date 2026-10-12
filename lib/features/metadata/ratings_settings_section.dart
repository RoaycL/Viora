import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/config/config_store.dart';
import '../../data/metadata/ratings_http.dart';
import '../../domain/models/external_rating.dart';
import '../../domain/models/ratings_settings.dart';
import '../../ui/panels/form_dialog.dart';
import '../../ui/widgets/form.dart';
import '../../ui/widgets/toast.dart';
import 'ratings_service.dart';

class RatingsSettingsSection extends ConsumerStatefulWidget {
  const RatingsSettingsSection({super.key});
  @override
  ConsumerState<RatingsSettingsSection> createState() => _RatingsSettingsSectionState();
}

class _RatingsSettingsSectionState extends ConsumerState<RatingsSettingsSection> {
  bool _saving = false;

  Future<bool> _save(RatingsSettings settings) async {
    if (_saving) return false;
    setState(() => _saving = true);
    try {
      await ref.read(ratingsSettingsProvider.notifier).save(settings);
      return true;
    } catch (e) {
      showToast('$e');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _configure(RatingsSettings settings, int i) async {
    if (_saving) return;
    final p = settings.providers[i];
    final key = TextEditingController(text: p.apiKey);
    final url = TextEditingController(text: p.effectiveUrl);
    await showFormDialog(
      context,
      title: '${p.id.label} 评分',
      saveLabel: '保存并测试',
      description: p.id == RatingProviderId.omdb
          ? '填写 OMDb Key，也可以粘贴申请邮件里的示例链接。用于 IMDb、烂番茄和 Metacritic 评分。'
          : '填写 Trakt 应用的 Client ID，公开评分无需登录，也无需 Client Secret。',
      children: [
        VTextField(
          label: p.id == RatingProviderId.omdb ? 'OMDb API Key' : 'Trakt Client ID',
          controller: key,
          obscure: true,
          autofocus: true,
          helper: p.id.builtinKey.isEmpty ? '留空清除凭据' : '留空使用构建时配置的凭据',
        ),
        const SizedBox(height: 20),
        VTextField(
          label: 'API 地址（可填写 HTTPS 反代，留空恢复默认）',
          controller: url,
          hint: p.id.defaultUrl,
          keyboardType: TextInputType.url,
        ),
      ],
      onSave: () async {
        String credential;
        final address = url.text.trim().isEmpty ? p.id.defaultUrl : url.text.trim();
        try {
          ratingEndpoint(Uri.parse(address), '');
          credential = normalizeRatingKey(p.id, key.text);
        } catch (e) {
          showToast(e is RatingsException ? e.message : '请检查 Key 和 HTTPS API 地址');
          return false;
        }
        final updated = p.copyWith(
          baseUrl: address,
          apiKey: credential,
          enabled: credential.isNotEmpty || p.id.builtinKey.isNotEmpty,
        );
        final next = settings.copyWith(providers: [...settings.providers]..[i] = updated);
        if (!await _save(next)) return false;
        if (!updated.configured) {
          showToast('${p.id.label} 凭据已清除');
          return true;
        }
        try {
          final resolver = await ref.read(ratingsResolverProvider.future);
          final result = await resolver.resolve(
            p.id,
            const RatingQuery(kind: RatingMediaKind.movie, imdbId: 'tt3896198'),
          );
          showToast(
            result.error != null
                ? '配置已保存；${result.error}'
                : result.data.ratings.isEmpty
                ? '配置已保存；测试作品暂无评分'
                : '${p.id.label} 连接成功',
          );
        } catch (_) {
          showToast('配置已保存；连接测试暂不可用');
        }
        return true;
      },
    );
    key.dispose();
    url.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(ratingsSettingsProvider);
    final settings = async.value;
    if (settings == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(async.hasError ? '读取评分设置失败' : '加载中…', style: VText.label),
          if (async.hasError)
            SmallIconButton(
              icon: Icons.refresh_rounded,
              label: '重试',
              onPressed: () => ref.invalidate(ratingsSettingsProvider),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '进入详情页时按作品 ID 查询，各来源独立显示。年龄分级是参考信息，不是详细家长指南。',
          style: VText.caption.copyWith(color: VColors.textSecondary),
        ),
        const SizedBox(height: 20),
        for (final (i, p) in settings.providers.indexed) ...[
          SettingsEntry(
            title: p.id == RatingProviderId.omdb ? 'OMDb · IMDb / 烂番茄 / Metacritic' : 'Trakt 社区评分',
            subtitle: p.effectiveUrl,
            status: p.configured ? '已配置' : '未配置',
            trailing: [
              SmallIconButton(
                icon: Icons.arrow_upward_rounded,
                onPressed: i == 0 ? null : () => _move(settings, i, -1),
              ),
              SmallIconButton(
                icon: Icons.arrow_downward_rounded,
                onPressed: i == settings.providers.length - 1 ? null : () => _move(settings, i, 1),
              ),
              SmallSwitch(
                value: p.enabled && p.configured,
                onChanged: (enabled) {
                  if (_saving) return;
                  if (enabled && !p.configured) {
                    showToast('请先填写凭据');
                    return;
                  }
                  _save(settings.copyWith(providers: [...settings.providers]..[i] = p.copyWith(enabled: enabled)));
                },
              ),
            ],
            onConfigure: () => _configure(settings, i),
          ),
          const SizedBox(height: 12),
        ],
        VToggle(
          label: '通过反向代理访问评分服务',
          subtitle: '使用上面填写的 HTTPS 反向代理地址',
          value: settings.useProxy,
          onChanged: (v) {
            if (_saving) return;
            final proxy = ref.read(configProvider).proxy;
            if (v && (!proxy.enabled || Uri.tryParse(proxy.baseUrl)?.scheme != 'https')) {
              showToast('请先配置 HTTPS 反向代理地址');
              return;
            }
            _save(settings.copyWith(useProxy: v));
          },
        ),
        const SizedBox(height: 12),
        VToggle(
          label: '同步评分凭据',
          subtitle: '将自行填写的 Key 和 Client ID 加入配置同步；默认只同步开关与地址',
          value: settings.syncKeys,
          onChanged: (v) {
            if (!_saving) _save(settings.copyWith(syncKeys: v));
          },
        ),
      ],
    );
  }

  void _move(RatingsSettings settings, int i, int delta) {
    if (_saving) return;
    final list = [...settings.providers];
    final item = list.removeAt(i);
    list.insert(i + delta, item);
    _save(settings.copyWith(providers: list));
  }
}
