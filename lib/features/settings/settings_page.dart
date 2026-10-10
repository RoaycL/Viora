import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/config/app_config.dart';
import '../../data/config/config_store.dart';
import '../../data/media/media_models.dart';
import '../../data/media/server_registry.dart';
import '../../data/net/request_composer.dart';
import '../../data/tmdb/tmdb_client.dart';
import '../../ui/focus/focus_auto_scroll.dart';
import '../../ui/focus/focusable.dart';
import '../../ui/focus/input_mode.dart';
import '../../ui/glass/glass.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/form.dart';
import '../../ui/widgets/toast.dart';
import '../update/update_controller.dart';
import '../update/update_dialog.dart';

/// 设置（docs/06-ui-design.md §9）：播放、反向代理（绑定线路）、关于与更新。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final _ua = TextEditingController();
  late final _client = TextEditingController();
  late final _device = TextEditingController();
  late final _proxy = TextEditingController();
  late final _manifest = TextEditingController();
  late final _tmdbKey = TextEditingController();
  late final _tmdbBase = TextEditingController();
  bool _tmdbTesting = false;
  _Category _category = _Category.playback;
  String _version = '';
  String _source = '';

  @override
  void initState() {
    super.initState();
    final c = ref.read(configProvider);
    _ua.text = c.playback.userAgent;
    _client.text = c.playback.clientName;
    _device.text = c.playback.deviceName;
    _proxy.text = c.proxy.baseUrl;
    _tmdbKey.text = c.tmdb.apiKey;
    _tmdbBase.text = c.tmdb.baseUrl;
    _load();
  }

  @override
  void dispose() {
    for (final c in [_ua, _client, _device, _proxy, _manifest, _tmdbKey, _tmdbBase]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final c = ref.read(updateControllerProvider.notifier);
    await c.loadSettings();
    final p = await c.packageInfo;
    final source = await c.sourceDescription();
    if (!mounted) return;
    setState(() {
      _version = 'v${p.version}（build ${p.buildNumber}）';
      _source = source;
      _manifest.text = c.settings.manifestUrl ?? '';
    });
  }

  Future<void> _savePlayback() async {
    await ref
        .read(configProvider.notifier)
        .update(
          (c) => c.copyWith(
            playback: c.playback.copyWith(
              userAgent: _ua.text.trim(),
              clientName: _client.text.trim().isEmpty ? 'Viora' : _client.text.trim(),
              deviceName: _device.text.trim(),
            ),
          ),
        );
    showToast('播放设置已保存');
  }

  Future<void> _saveProxy() async {
    var url = _proxy.text.trim();
    if (url.isNotEmpty && !url.contains('://')) url = 'https://$url';
    if (url.isNotEmpty && !url.endsWith('/')) url = '$url/';
    _proxy.text = url;
    await ref
        .read(configProvider.notifier)
        .update(
          (c) => c.copyWith(
            proxy: ProxyConfig(baseUrl: url, scope: c.proxy.scope),
          ),
        );
    showToast(url.isEmpty ? '已关闭反向代理' : '反向代理地址已保存');
  }

  Future<void> _saveTmdb() async {
    final store = ref.read(configProvider.notifier);
    await store.update(
      (c) => c.copyWith(
        tmdb: c.tmdb.copyWith(apiKey: _tmdbKey.text.trim(), baseUrl: _tmdbBase.text.trim()),
      ),
    );
    final config = ref.read(configProvider);
    if (!config.tmdb.enabled) {
      showToast('已清除 TMDB 设置');
      return;
    }
    setState(() => _tmdbTesting = true);
    try {
      final meta = await TmdbClient(config.tmdb, config.proxy).details(MediaKind.movie, '550');
      showToast('TMDB 连接成功：${meta?.title ?? ''}');
      ref.invalidate(zhMetaProvider);
    } catch (e) {
      showToast('TMDB 连接失败：${e is DioException ? (e.response?.statusCode ?? e.message) : e}');
    } finally {
      if (mounted) setState(() => _tmdbTesting = false);
    }
  }

  Future<void> _saveManifest() async {
    final c = ref.read(updateControllerProvider.notifier);
    final url = _manifest.text.trim();
    await c.saveSettings(UpdateSettings(autoCheck: c.settings.autoCheck, manifestUrl: url.isEmpty ? null : url));
    final source = await c.sourceDescription();
    setState(() => _source = source);
    showToast('更新来源已保存');
  }

  Future<void> _check() async {
    final info = await ref.read(updateControllerProvider.notifier).check();
    if (info != null && mounted) await showUpdateDialog(context, info);
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(configProvider);
    final state = ref.watch(updateControllerProvider);
    final updater = ref.read(updateControllerProvider.notifier);

    final String status = switch (state) {
      UpdateChecking() => '正在检查…',
      UpdateUpToDate() => '已是最新版本',
      UpdateAvailable(:final info) => '发现新版本 ${info.label}',
      UpdateDownloading(:final info) => '正在下载 ${info.label}…',
      UpdateInstalling(:final info) => '正在安装 ${info.label}',
      UpdateFailed(:final message) => message,
      UpdateIdle() => '',
    };

    final sections = <Widget>[
      // ───────── 播放 ─────────
      _Section(
        title: '播放',
        children: [
          VTextField(label: '播放 UA（自定义后以此 UA 播放；服务器里单独设置的优先）', controller: _ua, hint: defaultUserAgent(appVersion)),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: VTextField(label: '客户端名称（上报给 Emby / Jellyfin）', controller: _client),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: VTextField(label: '设备名称', controller: _device, hint: defaultDeviceName()),
              ),
            ],
          ),
          const SizedBox(height: 20),
          VToggle(
            label: 'API 与图片请求也使用播放 UA',
            subtitle: '默认只有视频流使用播放 UA',
            value: config.playback.uaForApi,
            onChanged: (v) =>
                ref.read(configProvider.notifier).update((c) => c.copyWith(playback: c.playback.copyWith(uaForApi: v))),
          ),
          const SizedBox(height: 12),
          VToggle(
            label: '快进 / 快退步长：${config.playback.seekStepSeconds} 秒',
            subtitle: '按 OK 在 5 / 10 / 15 / 30 秒之间切换',
            value: true,
            onChanged: (_) {
              const steps = [5, 10, 15, 30];
              final i = steps.indexOf(config.playback.seekStepSeconds);
              ref
                  .read(configProvider.notifier)
                  .update(
                    (c) => c.copyWith(playback: c.playback.copyWith(seekStepSeconds: steps[(i + 1) % steps.length])),
                  );
            },
          ),
          if (defaultTargetPlatform == TargetPlatform.android) ...[
            const SizedBox(height: 24),
            VChoice<EnginePreference>(
              label: '播放内核（Android）',
              options: const [
                (EnginePreference.auto, '自动（ExoPlayer，失败换 mpv）'),
                (EnginePreference.exo, 'ExoPlayer'),
                (EnginePreference.mpv, 'mpv'),
              ],
              value: config.playback.engine,
              onChanged: (v) =>
                  ref.read(configProvider.notifier).update((c) => c.copyWith(playback: c.playback.copyWith(engine: v))),
            ),
            const SizedBox(height: 16),
            VToggle(
              label: '自动帧率切换',
              subtitle: '按片源帧率切换电视刷新率（如 23.976 / 24 / 25Hz），避免画面卡顿',
              value: config.playback.autoFrameRate,
              onChanged: (v) => ref
                  .read(configProvider.notifier)
                  .update((c) => c.copyWith(playback: c.playback.copyWith(autoFrameRate: v))),
            ),
            const SizedBox(height: 12),
            VToggle(
              label: '隧道播放',
              subtitle: 'ExoPlayer 专用，部分电视盒子音画同步更好；出现黑屏或卡顿时请关闭',
              value: config.playback.tunneling,
              onChanged: (v) => ref
                  .read(configProvider.notifier)
                  .update((c) => c.copyWith(playback: c.playback.copyWith(tunneling: v))),
            ),
          ],
          const SizedBox(height: 24),
          PillButton(icon: Icons.save_rounded, label: '保存播放设置', onPressed: _savePlayback),
        ],
      ),

      // ───────── 元数据 ─────────
      _Section(
        title: '元数据 · TMDB',
        children: [
          Text(
            '媒体库里的标题、简介、类型不是中文时，用 TMDB 的简体中文数据补全；之后首页推荐也会用到。',
            style: VText.caption.copyWith(color: VColors.textSecondary),
          ),
          const SizedBox(height: 20),
          VTextField(label: 'TMDB API Key 或读取令牌（themoviedb.org → 设置 → API）', controller: _tmdbKey),
          const SizedBox(height: 20),
          VTextField(
            label: '自定义 API 地址（可留空）',
            controller: _tmdbBase,
            hint: 'https://api.themoviedb.org/3',
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 20),
          VToggle(
            label: '通过反向代理访问 TMDB',
            subtitle: '国内网络直连 TMDB 不稳定时打开（需先填写反向代理的完整地址）',
            value: config.tmdb.useProxy,
            onChanged: (v) =>
                ref.read(configProvider.notifier).update((c) => c.copyWith(tmdb: c.tmdb.copyWith(useProxy: v))),
          ),
          const SizedBox(height: 24),
          PillButton(
            icon: Icons.save_rounded,
            label: _tmdbTesting ? '测试中…' : '保存并测试',
            onPressed: _tmdbTesting ? null : _saveTmdb,
          ),
        ],
      ),

      // ───────── 反向代理 ─────────
      _Section(
        title: '反向代理 · 绑定线路',
        children: [
          VTextField(
            label: '完整地址（emby-reverse-proxy-go）',
            controller: _proxy,
            hint: 'https://embyproxy.example.com/proxy/',
            keyboardType: TextInputType.url,
            helper: '更换地址后，已绑定的线路会继续使用这个代理。示例：https://emby.a.com → …/proxy/https/emby.a.com/443',
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              PillButton(icon: Icons.save_rounded, label: '保存地址', onPressed: _saveProxy),
              const SizedBox(width: 24),
              PillButton(
                label: config.proxy.scope == ProxyScope.all ? '代理范围：API + 视频流' : '代理范围：仅视频流',
                onPressed: () => ref
                    .read(configProvider.notifier)
                    .update(
                      (c) => c.copyWith(
                        proxy: ProxyConfig(
                          baseUrl: c.proxy.baseUrl,
                          scope: c.proxy.scope == ProxyScope.all ? ProxyScope.streamOnly : ProxyScope.all,
                        ),
                      ),
                    ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Text('媒体服务器线路', style: VText.caption.copyWith(color: VColors.textTertiary)),
          const SizedBox(height: 12),
          if (config.servers.isEmpty)
            Text('还没有添加服务器', style: VText.label.copyWith(color: VColors.textMuted))
          else
            for (final s in config.servers)
              for (final l in s.lines) ...[
                VToggle(
                  label: '${s.name} · ${l.name}',
                  subtitle: l.url,
                  value: l.proxied,
                  onChanged: (v) => ref
                      .read(configProvider.notifier)
                      .updateServer(
                        s.id,
                        (old) =>
                            old.copyWith(lines: [for (final x in old.lines) x.id == l.id ? x.copyWith(proxied: v) : x]),
                      ),
                ),
                const SizedBox(height: 10),
              ],
        ],
      ),

      // ───────── 关于与更新 ─────────
      _Section(
        title: '关于与更新',
        children: [
          _InfoLine(label: '当前版本', value: _version),
          _InfoLine(label: '更新来源', value: _source),
          const SizedBox(height: 20),
          Row(
            children: [
              PillButton(
                icon: Icons.refresh_rounded,
                label: state is UpdateChecking ? '检查中…' : '检查更新',
                onPressed: state is UpdateChecking ? null : _check,
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Text(
                  status,
                  style: VText.caption.copyWith(color: state is UpdateFailed ? VColors.bad : VColors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          VToggle(
            label: '启动时自动检查更新',
            value: updater.settings.autoCheck,
            onChanged: (v) async {
              await updater.saveSettings(UpdateSettings(autoCheck: v, manifestUrl: updater.settings.manifestUrl));
              setState(() {});
            },
          ),
          const SizedBox(height: 20),
          VTextField(
            label: '自定义更新地址（latest.json，留空使用 GitHub Releases）',
            controller: _manifest,
            hint: 'https://example.com/viora/latest.json',
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 16),
          PillButton(icon: Icons.save_rounded, label: '保存更新地址', onPressed: _saveManifest),
        ],
      ),
    ];
    final current = _category.index.clamp(0, sections.length - 1);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 左：分类
        Padding(
          padding: const EdgeInsets.fromLTRB(VSpace.contentLeft, VSpace.safeV, 0, VSpace.safeV),
          child: SizedBox(
            width: 340,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('设置', style: VText.h1),
                const SizedBox(height: 40),
                for (final c in _Category.values) ...[
                  _CategoryItem(
                    category: c,
                    selected: c == _category,
                    autofocus: c == _Category.values.first,
                    onSelect: () => setState(() => _category = c),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(width: 48),
        // 右：当前分类的内容，铺满剩余宽度
        Expanded(
          child: FocusAutoScroll(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(0, VSpace.safeV + 92, VSpace.safeH, 240),
              child: sections[current],
            ),
          ),
        ),
      ],
    );
  }
}

enum _Category {
  playback('播放', Icons.play_circle_outline_rounded),
  metadata('元数据', Icons.auto_awesome_outlined),
  proxy('反向代理', Icons.shield_outlined),
  about('关于与更新', Icons.system_update_alt_rounded);

  const _Category(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// 左侧分类：OK / 点击选中；遥控器移动焦点时直接切换内容
class _CategoryItem extends StatelessWidget {
  const _CategoryItem({required this.category, required this.selected, required this.onSelect, this.autofocus = false});

  final _Category category;
  final bool selected;
  final bool autofocus;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return VFocusable(
      autofocus: autofocus,
      radius: 18,
      scale: 1.03,
      alignment: Alignment.centerLeft,
      showRing: false,
      onActivate: onSelect,
      onFocusChange: (focused) {
        if (focused && InputMode.shouldAutoScroll) onSelect();
      },
      builder: (context, focused) {
        final fg = focused ? const Color(0xFF0B0C10) : (selected ? Colors.white : VColors.textSecondary);
        return AnimatedContainer(
          duration: VMotion.focus,
          height: 68,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          decoration: BoxDecoration(
            color: focused ? Colors.white : (selected ? const Color(0x29FFFFFF) : const Color(0x00FFFFFF)),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Icon(category.icon, size: 28, color: fg),
              const SizedBox(width: 16),
              Text(
                category.label,
                style: VText.label.copyWith(color: fg, fontWeight: selected ? FontWeight.w700 : FontWeight.w400),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.zero,
      child: Glass(
        padding: const EdgeInsets.all(44),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [SectionTitle(title), ...children]),
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
