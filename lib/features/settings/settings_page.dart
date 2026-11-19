import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/desktop_prefs.dart';
import '../../app/desktop_tray.dart';
import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../../app/window_frame.dart' show isDesktopWindow;
import '../../core/platform/open_url.dart';
import '../../data/config/app_config.dart';
import '../../data/config/config_store.dart';
import '../../data/index/index_sync.dart';
import '../../data/media/server_registry.dart';
import '../../data/net/request_composer.dart';
import '../../data/tmdb/tmdb_client.dart';
import '../../player/playback_cache.dart';
import '../../ui/focus/focus_auto_scroll.dart';
import '../../ui/focus/focusable.dart';
import '../../ui/focus/input_mode.dart';
import '../../ui/glass/glass.dart';
import '../../ui/panels/context_menu.dart';
import '../../ui/panels/form_dialog.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/form.dart';
import '../../ui/widgets/toast.dart';
import '../danmaku/danmaku_settings_section.dart';
import '../metadata/ratings_service.dart';
import '../metadata/ratings_settings_section.dart';
import '../parental/parental_settings_section.dart';
import '../segments/segment_service.dart';
import '../segments/segment_settings_section.dart';
import '../sync/sync_settings_section.dart';
import '../update/update_controller.dart';
import '../update/update_dialog.dart';
import 'support_actions.dart';

/// 设置（docs/06-ui-design.md §9）：播放、片头片尾、弹幕、媒体服务器、接口与网络、同步与备份、通用与关于。
/// 文本框改完自动保存（停止输入 0.8 秒后，离开页面时也会保存），不需要点保存按钮。
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
  _Category _category = _Category.playback;

  /// Windows：左上角的设置搜索
  late final _search = TextEditingController()..addListener(() => setState(() {}));
  String _version = '';
  String _source = '';

  /// 保存时用的 store（离开页面时 ref 已不能用，提前取好）
  late final ConfigStore _store = ref.read(configProvider.notifier);
  late final UpdateController _updater = ref.read(updateControllerProvider.notifier);

  String _savedIdentity = '';
  String _savedProxy = '';

  /// 各文本框的延时自动保存
  final _pending = <String, (Timer, Future<void> Function())>{};

  void _autoSave(String key, Future<void> Function() save) {
    _pending.remove(key)?.$1.cancel();
    _pending[key] = (
      Timer(const Duration(milliseconds: 800), () {
        _pending.remove(key);
        save();
      }),
      save,
    );
  }

  @override
  void initState() {
    super.initState();
    final c = ref.read(configProvider);
    _refreshCacheSize();
    _ua.text = c.playback.userAgent;
    _client.text = c.playback.clientName;
    _device.text = c.playback.deviceName;
    _proxy.text = c.proxy.baseUrl;
    _tmdbKey.text = c.tmdb.apiKey;
    _tmdbBase.text = c.tmdb.baseUrl;
    _savedIdentity = '${_ua.text.trim()}\u0001${_client.text.trim()}\u0001${_device.text.trim()}';
    _savedProxy = _proxy.text.trim();
    for (final field in [_ua, _client, _device]) {
      field.addListener(() => _autoSave('identity', _saveIdentity));
    }
    _proxy.addListener(() => _autoSave('proxy', _saveProxy));
    _load();
  }

  @override
  void dispose() {
    // 还没到时间的自动保存立即执行
    for (final (timer, save) in _pending.values) {
      timer.cancel();
      save();
    }
    _pending.clear();
    for (final c in [_ua, _client, _device, _proxy, _manifest, _tmdbKey, _tmdbBase, _search]) {
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
    _manifest.addListener(() => _autoSave('manifest', _saveManifest));
  }

  /// 播放 UA、客户端名称、设备名称
  Future<void> _saveIdentity() async {
    final ua = _ua.text.trim(), client = _client.text.trim(), device = _device.text.trim();
    // 文本框移动光标也会触发监听：内容没变不保存
    final key = '$ua\u0001$client\u0001$device';
    if (key == _savedIdentity) return;
    _savedIdentity = key;
    await _store.update(
      (c) => c.copyWith(
        playback: c.playback.copyWith(userAgent: ua, clientName: client.isEmpty ? 'Viora' : client, deviceName: device),
      ),
    );
  }

  /// 反向代理地址：没写协议时补 https://，末尾补 /（只改保存的值，不改输入框，避免打字时跳动）
  Future<void> _saveProxy() async {
    if (_proxy.text.trim() == _savedProxy) return;
    _savedProxy = _proxy.text.trim();
    var url = _proxy.text.trim();
    if (url.isNotEmpty && !url.contains('://')) url = 'https://$url';
    if (url.isNotEmpty && !url.endsWith('/')) url = '$url/';
    await _store.update((c) => c.proxy.baseUrl == url ? c : c.copyWith(proxy: ProxyConfig(baseUrl: url)));
  }

  int? _cacheSize;

  void _updatePlayback(PlaybackConfig Function(PlaybackConfig) f) =>
      ref.read(configProvider.notifier).update((c) => c.copyWith(playback: f(c.playback)));

  Future<void> _refreshCacheSize() async {
    final size = await PlaybackCache.size();
    if (mounted) setState(() => _cacheSize = size);
  }

  Future<void> _clearCache() async {
    await PlaybackCache.clear();
    await _refreshCacheSize();
    showToast('播放缓存已清除');
  }

  static String _formatBytes(int b) => b >= 1 << 30
      ? '${(b / (1 << 30)).toStringAsFixed(1)} GB'
      : b >= 1 << 20
      ? '${(b / (1 << 20)).toStringAsFixed(0)} MB'
      : '${(b / 1024).toStringAsFixed(0)} KB';

  Future<void> _configureTmdb() async {
    final c = ref.read(configProvider).tmdb;
    _tmdbKey.text = c.apiKey;
    _tmdbBase.text = c.baseUrl;
    await showFormDialog(
      context,
      title: 'TMDB API',
      description: TmdbConfig.builtinToken.isEmpty
          ? '填写 TMDB 的 API Key 或读取令牌（themoviedb.org → 设置 → API）。'
          : '已内置读取令牌，可留空直接使用；填写自己的令牌后优先使用你的。',
      saveLabel: '保存并测试',
      children: [
        VTextField(label: 'API Key 或读取令牌', controller: _tmdbKey, obscure: true, autofocus: true),
        const SizedBox(height: 20),
        VTextField(
          label: '自定义 API 地址（可留空，也可以填自建的 TMDB 反代）',
          controller: _tmdbBase,
          hint: 'https://api.themoviedb.org/3',
          keyboardType: TextInputType.url,
        ),
      ],
      onSave: () async {
        await _saveTmdb();
        return true;
      },
    );
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
    try {
      final j = await TmdbClient(config.tmdb, config.proxy).get('/movie/550');
      showToast('TMDB 连接成功：${j['title'] ?? ''}');
      ref.invalidate(zhMetaProvider);
      ref.invalidate(tmdbRowProvider);
      ref.invalidate(tmdbPeopleProvider);
    } catch (e) {
      showToast('TMDB 连接失败：${e is DioException ? (e.response?.statusCode ?? e.message) : e}');
    }
  }

  Future<void> _saveManifest() async {
    final c = _updater;
    final url = _manifest.text.trim();
    if (url == (c.settings.manifestUrl ?? '')) return;
    await c.saveSettings(c.settings.copyWith(manifestUrl: url.isEmpty ? null : url, clearManifest: url.isEmpty));
    final source = await c.sourceDescription();
    if (mounted) setState(() => _source = source);
  }

  Future<void> _check() async {
    final info = await ref.read(updateControllerProvider.notifier).check();
    if (info != null && mounted) await showUpdateDialog(context, info);
  }

  /// 反向代理的汇总：哪些服务、哪些服务器线路经过代理，都在这里看、在这里开关（其他地方不再单独设置；
  /// 只有添加 / 编辑服务器时还能勾选，因为只能经代理连上的服务器要先连上才能保存）
  List<Widget> _proxyUsers(AppConfig config, UpdateController updater) {
    final hasProxy = config.proxy.enabled;
    final https = Uri.tryParse(config.proxy.baseUrl.trim())?.scheme == 'https';
    final ratings = ref.watch(ratingsSettingsProvider).value;
    final segments = ref.watch(segmentSettingsProvider).value;
    bool guard(bool on, {bool needHttps = false}) {
      if (!on) return true;
      if (!hasProxy) {
        showToast('请先填写上面的反向代理地址');
        return false;
      }
      if (needHttps && !https) {
        showToast('这项需要 HTTPS 的反向代理地址');
        return false;
      }
      return true;
    }

    Widget toggle(String label, String subtitle, bool value, ValueChanged<bool> onChanged, {bool needHttps = false}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: VToggle(
            label: label,
            subtitle: subtitle,
            value: value && hasProxy,
            onChanged: (v) {
              if (guard(v, needHttps: needHttps)) onChanged(v);
            },
          ),
        );

    return [
      Text('经过反向代理的服务', style: VText.label.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Text(
        hasProxy ? '打开的服务经上面的地址访问；国内直连不稳定的服务打开即可。内网地址始终直连。' : '先填写上面的地址，才能打开下面的开关。',
        style: VText.small.copyWith(color: VColors.textTertiary, height: 1.6),
      ),
      const SizedBox(height: 16),
      toggle(
        'TMDB',
        '元数据、推荐和图片（image.tmdb.org）',
        config.tmdb.useProxy,
        (v) => ref.read(configProvider.notifier).update((c) => c.copyWith(tmdb: c.tmdb.copyWith(useProxy: v))),
      ),
      if (ratings != null)
        toggle(
          '外部评分',
          'OMDb、Trakt、MDBList（IMDb / 烂番茄 / Metacritic）',
          ratings.useProxy,
          (v) => ref.read(ratingsSettingsProvider.notifier).save(ratings.copyWith(useProxy: v)),
          needHttps: true,
        ),
      if (segments != null)
        toggle(
          '片头片尾数据库',
          'TheIntroDB 等第三方片头片尾数据',
          segments.useProxy,
          (v) => ref.read(segmentSettingsProvider.notifier).save(segments.copyWith(useProxy: v)),
        ),
      toggle('应用更新', '检查和下载更新（GitHub）。关闭时直连失败也会自动改走反向代理再试一次', updater.settings.useProxy, (v) async {
        await updater.saveSettings(updater.settings.copyWith(useProxy: v));
        if (mounted) setState(() {});
      }),
      const SizedBox(height: 14),
      Text('媒体服务器线路', style: VText.label.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Text(
        '勾选的线路：登录、浏览、图片和视频播放全部经过代理。添加 / 编辑服务器时也可以勾选。',
        style: VText.small.copyWith(color: VColors.textTertiary, height: 1.6),
      ),
      const SizedBox(height: 16),
      if (config.servers.isEmpty)
        Text('还没有添加服务器', style: VText.label.copyWith(color: VColors.textMuted))
      else
        for (final s in config.servers)
          for (final l in s.lines)
            toggle(
              '${s.displayName} · ${l.name}',
              l.url,
              l.proxied,
              (v) => ref
                  .read(configProvider.notifier)
                  .updateServer(
                    s.id,
                    (old) =>
                        old.copyWith(lines: [for (final x in old.lines) x.id == l.id ? x.copyWith(proxied: v) : x]),
                  ),
            ),
    ];
  }

  List<Widget> _categoryItems() => [
    for (final c in _Category.values) ...[
      _CategoryItem(
        category: c,
        selected: c == _category,
        autofocus: c == _Category.values.first,
        onSelect: () => setState(() => _category = c),
      ),
      const SizedBox(height: 10),
    ],
  ];

  List<Widget> _searchResults(String query) {
    final hits = _searchSettings(query);
    if (hits.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(left: 8, top: 8),
          child: Text('没有找到相关设置', style: VText.label.copyWith(color: VColors.textTertiary)),
        ),
      ];
    }
    return [
      for (final h in hits) ...[
        _SearchHit(
          entry: h,
          onSelect: () {
            _search.clear();
            setState(() => _category = h.category);
          },
        ),
        const SizedBox(height: 6),
      ],
    ];
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
          VToggle(
            label: '播放预加载',
            subtitle: '在详情页、继续观看上停留时提前准备播放信息并预热视频；剧集看到 85% 时预加载下一集。会多用少量流量',
            value: config.playback.preload,
            onChanged: (v) =>
                ref.read(configProvider.notifier).update((c) => c.copyWith(playback: c.playback.copyWith(preload: v))),
          ),
          if (config.playback.preload) ...[
            const SizedBox(height: 20),
            VChoice<int>(
              label: '起播预热量（按下播放前提前读取的数据：片头、续播位置、片尾索引）',
              options: [for (final mb in PlaybackConfig.warmChoices) (mb, '$mb MB')],
              value: config.playback.warmMb,
              onChanged: (v) => _updatePlayback((p) => p.copyWith(warmMb: v)),
            ),
          ],
          const SizedBox(height: 20),
          VChoice<int>(
            label: PlatformProfile.isTv
                ? '播放缓冲上限（边播边预读的最大数据量；电视内存有限，实际最多使用应用可用内存的 25%、预读 10 分钟）'
                : '播放缓冲上限（边播边预读的最大数据量；超过 256 MB 时写入磁盘缓存，不占内存）',
            options: [for (final mb in PlaybackConfig.bufferChoices) (mb, mb >= 1024 ? '${mb ~/ 1024} GB' : '$mb MB')],
            value: config.playback.bufferMb,
            onChanged: (v) => _updatePlayback((p) => p.copyWith(bufferMb: v)),
          ),
          const SizedBox(height: 20),
          VChoice<SourceOrder>(
            label: '资源排序（一部片有多个版本时默认选哪个；播放失败自动换源也按这个顺序。这部剧上次用的服务器始终排最前）',
            options: const [
              (SourceOrder.quality, '画质优先'),
              (SourceOrder.speed, '速度优先'),
              (SourceOrder.server, '指定服务器优先'),
            ],
            value: config.playback.sourceOrder,
            onChanged: (v) => _updatePlayback((p) => p.copyWith(sourceOrder: v)),
          ),
          if (config.playback.sourceOrder == SourceOrder.server) ...[
            const SizedBox(height: 12),
            PillButton(
              icon: Icons.dns_rounded,
              label: '优先的服务器：${config.server(config.playback.pinnedServerId ?? '')?.displayName ?? '未选择'}',
              onPressed: () => showContextMenu(
                context,
                title: '优先使用哪台服务器',
                actions: [
                  for (final s in config.servers)
                    MenuAction(
                      '${s.displayName}${s.id == config.playback.pinnedServerId ? '  ✓' : ''}',
                      Icons.dns_rounded,
                      () => _updatePlayback((p) => p.copyWith(pinnedServerId: s.id)),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          VChoice<SubtitlePreference>(
            label: '默认字幕（片子里有这种语言时起播自动选上，内封字幕优先；没有就沿用片源默认的字幕）',
            options: const [
              (SubtitlePreference.auto, '跟随片源'),
              (SubtitlePreference.zhHans, '简体中文'),
              (SubtitlePreference.zhHant, '繁体中文'),
              (SubtitlePreference.en, '英文'),
              (SubtitlePreference.off, '不显示'),
            ],
            value: config.playback.subtitlePreference,
            onChanged: (v) => _updatePlayback((p) => p.copyWith(subtitlePreference: v)),
          ),
          const SizedBox(height: 20),
          VToggle(
            label: '关闭播放器后清除播放缓存',
            subtitle: '退出播放时删除磁盘缓存文件和预加载的数据（连播下一集时保留）',
            value: config.playback.clearCacheOnExit,
            onChanged: (v) => _updatePlayback((p) => p.copyWith(clearCacheOnExit: v)),
          ),
          const SizedBox(height: 20),
          VToggle(
            label: '连续自动播放 3 集后询问「还在观看吗？」',
            subtitle: '中间没有任何按键 / 点击时暂停并询问，避免睡着了一直播下去',
            value: config.playback.askStillWatching,
            onChanged: (v) => _updatePlayback((p) => p.copyWith(askStillWatching: v)),
          ),
          const SizedBox(height: 16),
          PillButton(
            icon: Icons.cleaning_services_outlined,
            label: _cacheSize == null ? '立即清除播放缓存' : '立即清除播放缓存（当前 ${_formatBytes(_cacheSize!)}）',
            onPressed: _clearCache,
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
          if (PlatformProfile.isTv) ...[
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
        ],
      ),

      // ───────── 片头片尾 ─────────
      const _Section(title: '片头片尾', children: [SegmentSettingsSection()]),

      // ───────── 弹幕 ─────────
      const _Section(title: '弹幕', children: [DanmakuSettingsSection()]),

      // ───────── 媒体服务器 ─────────
      _Section(
        title: '媒体服务器',
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
          const SizedBox(height: 36),
          const _Subtitle('聚合搜索'),
          Text(
            '进入详情页时，会在勾选的服务器上查找同一部作品，列出各服务器的版本供选择、播放中切换。'
            '不勾选的服务器不参与查找，只在浏览它自己的媒体库时使用；「搜索」页仍然会搜索所有服务器。',
            style: VText.small.copyWith(color: VColors.textTertiary, height: 1.6),
          ),
          const SizedBox(height: 20),
          if (config.servers.isEmpty)
            Text('还没有添加服务器', style: VText.label.copyWith(color: VColors.textMuted))
          else
            for (final s in config.servers) ...[
              VToggle(
                label: s.displayName,
                subtitle: [
                  s.type == ServerType.emby ? 'Emby' : 'Jellyfin',
                  if (s.lines.isNotEmpty) s.lines.first.url,
                  if (!s.loggedIn) '未登录',
                ].join(' · '),
                value: s.aggregate,
                onChanged: (v) =>
                    ref.read(configProvider.notifier).updateServer(s.id, (old) => old.copyWith(aggregate: v)),
              ),
              const SizedBox(height: 10),
            ],
          const SizedBox(height: 36),
          const _Subtitle('本地索引'),
          Text(
            '在本机保存一份片库目录，用于首字母搜索、单字搜索和首页「最近入库」。启动时只同步新增内容，每 30 天完整同步一次。'
            '偶尔用、片库特别大或同步总出错的服务器可以关掉：关掉后删除它的本地索引，搜索时实时向它查询（输入两个字以上才查），'
            '它的新片也不出现在「最近入库」。',
            style: VText.small.copyWith(color: VColors.textTertiary, height: 1.6),
          ),
          const SizedBox(height: 20),
          if (config.servers.isEmpty)
            Text('还没有添加服务器', style: VText.label.copyWith(color: VColors.textMuted))
          else
            for (final s in config.servers) ...[
              VToggle(
                label: s.displayName,
                subtitle: s.indexEnabled ? '已开启' : '已关闭 · 只实时搜索',
                value: s.indexEnabled,
                onChanged: (v) async {
                  await ref.read(configProvider.notifier).updateServer(s.id, (old) => old.copyWith(indexEnabled: v));
                  if (v) unawaited(ref.read(indexSyncProvider.notifier).syncServer(s.id, forceFull: true));
                },
              ),
              const SizedBox(height: 10),
            ],
        ],
      ),

      // ───────── 接口与网络 ─────────
      _Section(
        title: '接口与网络',
        children: [
          Text(
            '所有第三方服务的 API Key、地址集中在这里。哪些服务走反向代理，统一在下面的「反向代理」里设置。',
            style: VText.small.copyWith(color: VColors.textTertiary, height: 1.6),
          ),
          const SizedBox(height: 24),
          const _Subtitle('反向代理'),
          VTextField(
            label: '完整地址（emby-reverse-proxy-go，留空关闭）',
            controller: _proxy,
            hint: 'https://embyproxy.example.com/proxy/',
            keyboardType: TextInputType.url,
            helper: '下面勾选的服务和服务器线路经过这个代理。示例：https://emby.a.com → …/proxy/https/emby.a.com/443',
          ),
          const SizedBox(height: 24),
          ..._proxyUsers(config, updater),
          // 仅 Windows：跟随系统代理（Clash 等工具开的系统代理），只存在本机
          if (isDesktopWindow) ...[
            const SizedBox(height: 36),
            const _Subtitle('系统代理'),
            ValueListenableBuilder<bool>(
              valueListenable: DesktopPrefs.instance.followSystemProxy,
              builder: (context, on, _) => VToggle(
                label: '跟随 Windows 系统代理',
                subtitle: on
                    ? (SystemProxy.current == null
                          ? '已打开，但系统现在没有开代理：照常直连'
                          : '经过 ${SystemProxy.current}：应用里所有请求和视频播放都走它，局域网地址直连')
                    : '打开后应用里所有请求和视频播放都走系统代理（设置 → 网络和 Internet → 代理）',
                value: on,
                onChanged: (v) async {
                  await DesktopPrefs.instance.setFollowSystemProxy(v);
                  if (mounted) setState(() {});
                },
              ),
            ),
          ],
          const SizedBox(height: 36),
          const _Subtitle('TMDB（元数据、推荐、中文标题）'),
          Text(
            TmdbConfig.builtinToken.isEmpty
                ? '首页推荐、详情页演职员 / 相似推荐，以及媒体库不是中文时的标题简介补全，都来自 TMDB。'
                : '已内置 TMDB 读取令牌，可直接使用；填写自己的令牌后优先使用你的。',
            style: VText.caption.copyWith(color: VColors.textSecondary),
          ),
          const SizedBox(height: 20),
          SettingsEntry(
            title: 'TMDB API',
            subtitle: config.tmdb.baseUrl.trim().isEmpty ? 'api.themoviedb.org' : config.tmdb.baseUrl.trim(),
            status: config.tmdb.apiKey.trim().isNotEmpty
                ? '使用自己的令牌'
                : (TmdbConfig.builtinToken.isNotEmpty ? '使用内置令牌' : '未配置'),
            onConfigure: _configureTmdb,
          ),
          const SizedBox(height: 36),
          const _Subtitle('评分（OMDb / Trakt / MDBList）'),
          const RatingsSettingsSection(),
          const SizedBox(height: 36),
          const _Subtitle('片头片尾数据库'),
          const SegmentSettingsSection(apiSources: true),
          const SizedBox(height: 36),
          const _Subtitle('弹幕服务器'),
          const DanmakuSettingsSection(servers: true),
          const SizedBox(height: 36),
          const _Subtitle('应用更新'),
          VTextField(
            label: '自定义更新地址（latest.json，留空使用 GitHub Releases）',
            controller: _manifest,
            hint: 'https://example.com/viora/latest.json',
            keyboardType: TextInputType.url,
          ),
        ],
      ),

      // ───────── 同步与备份 ─────────
      const _Section(title: '同步与备份', children: [SyncSettingsSection()]),

      // ───────── 界面与窗口 ─────────
      _Section(
        title: _Category.display.label,
        children: [
          // 仅电视：低配模式（默认开，只存在本机）
          if (PlatformProfile.isTv) ...[
            ValueListenableBuilder<bool>(
              valueListenable: PerfMode.liteSetting,
              builder: (context, lite, _) => VToggle(
                label: '流畅优先',
                subtitle: lite
                    ? '已开启：关掉毛玻璃模糊、加载动画、卡片浮现动画，弹幕每秒 30 帧，2GB 内存的电视盒子也流畅'
                    : '已关闭：显示完整的动画和毛玻璃效果（适合性能好的电视盒子）。卡顿时请重新打开（重新进入页面后生效）',
                value: lite,
                onChanged: (v) async {
                  await PerfMode.set(v);
                  if (mounted) setState(() {});
                },
              ),
            ),
            const SizedBox(height: 24),
          ],
          // 仅 Windows：关闭窗口时退出还是隐藏到托盘（默认隐藏到托盘）
          if (isDesktopWindow) ...[
            ValueListenableBuilder<bool>(
              valueListenable: DesktopPrefs.instance.fullScreenOnLaunch,
              builder: (context, v, _) =>
                  VToggle(label: '打开软件时全屏', value: v, onChanged: DesktopPrefs.instance.setFullScreenOnLaunch),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<bool>(
              valueListenable: DesktopPrefs.instance.fullScreenOnPlay,
              builder: (context, v, _) => VToggle(
                label: '开始播放时全屏',
                subtitle: '退出播放后恢复原来的窗口；连播下一集时保持全屏',
                value: v,
                onChanged: DesktopPrefs.instance.setFullScreenOnPlay,
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<AppIconStyle>(
              valueListenable: DesktopPrefs.instance.iconStyle,
              builder: (context, v, _) => VChoice<AppIconStyle>(
                label: '桌面图标（任务栏、桌面和开始菜单的快捷方式；应用里的图标不变）',
                options: [for (final s in AppIconStyle.values) (s, s.label)],
                value: v,
                onChanged: DesktopPrefs.instance.setIconStyle,
              ),
            ),
            const SizedBox(height: 24),
            ValueListenableBuilder<bool>(
              valueListenable: DesktopPrefs.instance.navCompact,
              builder: (context, compact, _) => VChoice<bool>(
                label: '左侧导航栏',
                options: const [(false, '默认（一长条）'), (true, '紧凑（上下居中）')],
                value: compact,
                onChanged: DesktopPrefs.instance.setNavCompact,
              ),
            ),
            const SizedBox(height: 24),
            ValueListenableBuilder<bool>(
              valueListenable: DesktopTray.instance.closeToTray,
              builder: (context, toTray, _) => VToggle(
                label: '关闭窗口时最小化到托盘',
                subtitle: toTray ? '点关闭只隐藏窗口；单击右下角托盘图标恢复，右键托盘图标可以退出' : '关闭：点关闭直接退出应用',
                value: toTray,
                onChanged: (v) => DesktopTray.instance.setCloseToTray(v),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),

      // ───────── 家长控制 ─────────
      const _Section(title: '家长控制', children: [ParentalSettingsSection()]),

      // ───────── 关于与更新 ─────────
      _Section(
        title: '关于与更新',
        children: [
          _InfoLine(label: '当前版本', value: _version),
          _InfoLine(
            label: '更新来源',
            value: _source,
            // 自定义清单地址时打开清单所在的网站，否则打开项目主页
            onTap: () => openExternalUrl(
              context,
              updater.settings.manifestUrl == null
                  ? UpdateController.homepage
                  : Uri.parse(updater.settings.manifestUrl!).replace(path: '/', query: ''),
              title: 'Viora 项目主页',
            ),
          ),
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
              await updater.saveSettings(updater.settings.copyWith(autoCheck: v));
              setState(() {});
            },
          ),
          const SizedBox(height: 20),
          VToggle(
            label: '检查测试版',
            subtitle: '打开：测试版和正式版都检查，有更新的就提示；关闭：只检查正式版（测试版可能不稳定）',
            value: updater.settings.includePrerelease,
            onChanged: (v) async {
              await updater.saveSettings(updater.settings.copyWith(includePrerelease: v));
              setState(() {});
            },
          ),
          const SizedBox(height: 24),
          SettingsEntry(
            title: '导出日志',
            subtitle: PlatformProfile.isTv ? '出问题时导出最近的运行日志：手机扫码查看 / 保存' : '出问题时导出最近的运行日志，保存成文件发给开发者',
            onConfigure: () => exportLogs(context, ref),
          ),
          const SizedBox(height: 40),
          const _TmdbAttribution(),
        ],
      ),
    ];
    final current = _category.index.clamp(0, sections.length - 1);

    return InfoTipScope(
      child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 左：分类
        Padding(
          padding: EdgeInsets.fromLTRB(VSpace.contentLeft, VSpace.pageTop, 0, VSpace.safeV),
          child: SizedBox(
            width: 340,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('设置', style: VText.h1),
                SizedBox(height: PlatformProfile.isDesktop ? 24 : 40),
                if (PlatformProfile.isDesktop) ...[_SearchBox(controller: _search), const SizedBox(height: 20)],
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _search.text.trim().isEmpty ? _categoryItems() : _searchResults(_search.text),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 48),
        // 右：外框与导航栏共用上下安全区，只有框内设置项滚动。
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(0, VSpace.pageTop, VSpace.safeH, VSpace.safeV),
            child: Glass(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(VRadius.panel),
                child: FocusAutoScroll(
                  child: SingleChildScrollView(padding: const EdgeInsets.all(44), child: sections[current]),
                ),
              ),
            ),
          ),
        ),
      ],
      ),
    );
  }
}

/// 设置搜索的索引：每个设置项的名字、所在分类和别名（搜「代理」「UA」「字幕」等都能找到）
class _SettingIndexEntry {
  const _SettingIndexEntry(this.title, this.category, [this.keywords = '']);

  final String title;
  final _Category category;
  final String keywords;
}

const _settingIndex = <_SettingIndexEntry>[
  // 播放
  _SettingIndexEntry('播放预加载', _Category.playback, '预热 流量 下一集'),
  _SettingIndexEntry('起播预热量', _Category.playback, '预加载 MB'),
  _SettingIndexEntry('播放缓冲', _Category.playback, '缓存 内存 buffer'),
  _SettingIndexEntry('资源排序', _Category.playback, '多版本 画质优先 速度优先 指定服务器 换源'),
  _SettingIndexEntry('默认字幕', _Category.playback, '字幕语言 简体 繁体 英文 内封 subtitle'),
  _SettingIndexEntry('关闭播放器后清除播放缓存', _Category.playback, '缓存 磁盘'),
  _SettingIndexEntry('还在观看吗', _Category.playback, '连续播放 自动播放 睡着'),
  _SettingIndexEntry('立即清除播放缓存', _Category.playback, '缓存 清理'),
  _SettingIndexEntry('快进 / 快退步长', _Category.playback, '快进 快退 秒'),
  _SettingIndexEntry('播放内核', _Category.playback, 'mpv ExoPlayer 安卓 电视'),
  _SettingIndexEntry('自动帧率切换', _Category.playback, '刷新率 帧率 电视'),
  _SettingIndexEntry('隧道播放', _Category.playback, 'ExoPlayer 音画同步'),
  // 片头片尾
  _SettingIndexEntry('自动跳过片头 / 前情提要 / 片尾', _Category.segments, '跳过 片头 片尾 前情提要 下一集 skip'),
  _SettingIndexEntry('第一集不自动跳过片头', _Category.segments, '第一集 片头'),
  _SettingIndexEntry('片头片尾数据来源', _Category.segments, 'TheIntroDB 手动标记 章节 Intro Skipper API Key'),
  // 弹幕
  _SettingIndexEntry('弹幕服务器', _Category.danmaku, '弹幕源 danmu_api 地址 token'),
  _SettingIndexEntry('播放时显示弹幕', _Category.danmaku, '弹幕开关'),
  _SettingIndexEntry('弹幕数量上限', _Category.danmaku, '密度 数量'),
  _SettingIndexEntry('弹幕字号 / 不透明度 / 显示区域 / 速度', _Category.danmaku, '字号 透明度 区域 速度 大小'),
  _SettingIndexEntry('顶部 / 底部弹幕、繁简转换、弹幕颜色', _Category.danmaku, '繁简 颜色 固定弹幕'),
  _SettingIndexEntry('弹幕屏蔽词', _Category.danmaku, '屏蔽 关键词 剧透'),
  // 媒体服务器
  _SettingIndexEntry('播放 UA', _Category.servers, 'User-Agent UA 客户端'),
  _SettingIndexEntry('客户端名称 / 设备名称', _Category.servers, 'Emby Jellyfin 设备'),
  _SettingIndexEntry('API 与图片请求也使用播放 UA', _Category.servers, 'UA'),
  _SettingIndexEntry('聚合搜索', _Category.servers, '搜索 服务器'),
  _SettingIndexEntry('本地索引', _Category.servers, '索引 搜索 拼音'),
  // 接口与网络
  _SettingIndexEntry('反向代理', _Category.network, '代理 proxy emby-reverse-proxy-go 线路'),
  _SettingIndexEntry('跟随 Windows 系统代理', _Category.network, '系统代理 Clash VPN proxy'),
  _SettingIndexEntry('TMDB API', _Category.network, 'TMDB API Key 元数据 推荐 中文标题'),
  _SettingIndexEntry('评分', _Category.network, 'OMDb Trakt MDBList IMDb 烂番茄'),
  _SettingIndexEntry('片头片尾数据库', _Category.network, 'TheIntroDB 代理'),
  _SettingIndexEntry('自定义更新地址', _Category.network, 'latest.json GitHub 更新'),
  // 同步与备份
  _SettingIndexEntry('发送到电视 / 接收配置', _Category.sync, '扫码 二维码 电视 手机 同步'),
  _SettingIndexEntry('配置备份', _Category.sync, '导入 导出 备份 文件'),
  _SettingIndexEntry('WebDAV 同步', _Category.sync, 'WebDAV 坚果云 同步 云'),
  // 界面与窗口
  _SettingIndexEntry('流畅优先', _Category.display, '低配 动画 毛玻璃 性能 电视'),
  _SettingIndexEntry('打开软件时全屏', _Category.display, '全屏 启动'),
  _SettingIndexEntry('开始播放时全屏', _Category.display, '全屏 播放'),
  _SettingIndexEntry('桌面图标', _Category.display, '图标 任务栏 快捷方式 日间 夜间'),
  _SettingIndexEntry('左侧导航栏', _Category.display, '导航 紧凑'),
  _SettingIndexEntry('关闭窗口时最小化到托盘', _Category.display, '托盘 关闭 退出 后台'),
  // 家长控制
  _SettingIndexEntry('家长控制', _Category.parental, '儿童 分级 PIN 年龄'),
  // 关于与更新
  _SettingIndexEntry('检查更新', _Category.about, '版本 更新 升级'),
  _SettingIndexEntry('启动时自动检查更新', _Category.about, '自动更新'),
  _SettingIndexEntry('检查测试版', _Category.about, '测试版 预发布 beta'),
  _SettingIndexEntry('导出日志', _Category.about, '日志 log 反馈 问题'),
];

/// 搜索结果的「设置名 · 分类」（测试用）
@visibleForTesting
List<String> settingSearchLabels(String query) => [
  for (final e in _searchSettings(query)) '${e.title} · ${e.category.label}',
];

/// 按名字、分类名和别名搜索设置项（不分大小写，空格分开的多个词都要匹配）
List<_SettingIndexEntry> _searchSettings(String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return const [];
  final tv = PlatformProfile.isTv;
  return [
    for (final e in _settingIndex)
      // 电视上没有的 Windows 专属设置不列出来
      if (!(tv && e.category == _Category.display && e.title != '流畅优先') &&
          !(!tv && const {'流畅优先', '播放内核', '自动帧率切换', '隧道播放'}.contains(e.title)))
        if (words.every('${e.title} ${e.category.label} ${e.keywords}'.toLowerCase().contains)) e,
  ];
}

/// 设置搜索框（Windows）
class _SearchBox extends StatelessWidget {
  const _SearchBox({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(color: const Color(0x14FFFFFF), borderRadius: BorderRadius.circular(VRadius.sm)),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, size: 22, color: VColors.textTertiary),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              style: VText.label,
              cursorColor: Colors.white,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: '搜索设置',
                hintStyle: VText.label.copyWith(color: VColors.textTertiary),
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            GestureDetector(
              onTap: controller.clear,
              child: const MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Icon(Icons.close_rounded, size: 20, color: VColors.textTertiary),
              ),
            ),
        ],
      ),
    );
  }
}

/// 搜索结果：设置名 + 所在分类，点击跳到那个分类
class _SearchHit extends StatelessWidget {
  const _SearchHit({required this.entry, required this.onSelect});

  final _SettingIndexEntry entry;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return VFocusable(
      semanticLabel: entry.title,
      radius: VRadius.sm,
      scale: 1,
      alignment: Alignment.centerLeft,
      showRing: false,
      onActivate: onSelect,
      builder: (context, focused) => AnimatedContainer(
        duration: VMotion.duration(context, VMotion.focus),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: focused ? const Color(0x1FFFFFFF) : const Color(0x00FFFFFF),
          borderRadius: BorderRadius.circular(VRadius.sm),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.title, style: VText.label),
            Text(entry.category.label, style: VText.small.copyWith(color: VColors.textTertiary)),
          ],
        ),
      ),
    );
  }
}

enum _Category {
  playback('播放', Icons.play_circle_outline_rounded),
  segments('片头片尾', Icons.fast_forward_outlined),
  danmaku('弹幕', Icons.chat_outlined),
  servers('媒体服务器', Icons.dns_outlined),
  network('接口与网络', Icons.hub_outlined),
  sync('同步与备份', Icons.qr_code_2_rounded),
  display('界面与窗口', Icons.tune_rounded),
  parental('家长控制', Icons.shield_outlined),
  about('关于与更新', Icons.info_outline_rounded);

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
      semanticLabel: category.label,
      selected: selected,
      radius: VRadius.sm,
      scale: PlatformProfile.isTv ? 1.03 : 1,
      alignment: Alignment.centerLeft,
      showRing: false,
      onActivate: onSelect,
      onFocusChange: (focused) {
        if (focused && InputMode.shouldAutoScroll) onSelect();
      },
      builder: (context, focused) {
        // Windows：低调的悬停底色 + 选中项左侧强调条；电视：焦点白底，远处也能看清
        final tv = PlatformProfile.isTv;
        final fg = tv && focused
            ? const Color(0xFF0B0C10)
            : (selected || focused ? Colors.white : VColors.textSecondary);
        final bg = tv
            ? (focused ? Colors.white : (selected ? const Color(0x29FFFFFF) : const Color(0x00FFFFFF)))
            : (selected ? const Color(0x1FFFFFFF) : (focused ? const Color(0x0FFFFFFF) : const Color(0x00FFFFFF)));
        return AnimatedContainer(
          duration: VMotion.duration(context, VMotion.focus),
          height: tv ? 68 : 56,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(VRadius.sm)),
          child: Row(
            children: [
              if (!tv) ...[
                AnimatedContainer(
                  duration: VMotion.focus,
                  width: 4,
                  height: selected ? 24 : 0,
                  decoration: BoxDecoration(color: VColors.accent, borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: 14),
              ],
              Icon(category.icon, size: tv ? 28 : 24, color: fg),
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
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [SectionTitle(title), ...children]);
  }
}

/// 分类内的小标题
class _Subtitle extends StatelessWidget {
  const _Subtitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Text(text, style: VText.rowTitle.copyWith(fontSize: 26)),
  );
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value, this.onTap});

  final String label;
  final String value;

  /// 可点击（链接）：遥控器也能聚焦
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Text(value, style: VText.label);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(
            width: 160,
            child: Text(label, style: VText.label.copyWith(color: VColors.textTertiary)),
          ),
          if (onTap == null)
            Expanded(child: text)
          else
            VFocusable(
              onActivate: onTap,
              radius: VRadius.sm,
              scale: 1.02,
              showRing: false,
              alignment: Alignment.centerLeft,
              builder: (context, focused) => AnimatedContainer(
                duration: VMotion.focus,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: focused ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(VRadius.sm),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      value,
                      style: VText.label.copyWith(
                        color: focused ? const Color(0xFF0B0C10) : VColors.accent,
                        decoration: focused ? null : TextDecoration.underline,
                        decorationColor: VColors.accent,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.open_in_new_rounded,
                      size: 20,
                      color: focused ? const Color(0xFF0B0C10) : VColors.accent,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// TMDB 署名（TMDB API 使用条款要求）
class _TmdbAttribution extends StatelessWidget {
  const _TmdbAttribution();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: const Color(0x0AFFFFFF), borderRadius: BorderRadius.circular(VRadius.md)),
      child: Row(
        children: [
          Image.asset('assets/images/tmdb_logo.png', height: 28, filterQuality: FilterQuality.medium),
          const SizedBox(width: 28),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('影视元数据、图片与推荐来自 TMDB（themoviedb.org）', style: VText.label.copyWith(fontSize: 20)),
                const SizedBox(height: 6),
                Text(
                  'This product uses the TMDB API but is not endorsed or certified by TMDB.',
                  style: VText.small.copyWith(color: VColors.textTertiary),
                ),
                const SizedBox(height: 6),
                Text(
                  'Emby、Jellyfin 图标归各自项目所有，仅用于标识服务器类型；Jellyfin 图标按 CC BY-SA 4.0 使用。',
                  style: VText.small.copyWith(color: VColors.textTertiary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
