import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../../data/config/config_store.dart';
import '../../data/index/index_sync.dart';
import '../../data/media/server_registry.dart';
import '../../data/net/request_composer.dart';
import '../../data/sync/config_payload.dart';
import '../../domain/models/segment_settings.dart';
import '../../data/sync/config_receiver.dart';
import '../../data/sync/config_sender.dart';
import '../../data/sync/webdav_sync.dart';
import '../../data/config/app_config.dart';
import '../../ui/panels/context_menu.dart';
import '../../ui/glass/glass.dart';
import '../../ui/panels/form_dialog.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/form.dart';
import '../../ui/widgets/toast.dart';
import '../segments/segment_service.dart';
import '../settings/support_actions.dart';
import 'webdav_service.dart';

/// 设置 → 同步配置（docs/11-sync.md）
///
/// 电视：「接收配置」——屏幕上显示二维码和配对码，手机扫码填写，或 Windows 一键发送。
/// Windows：「发送到电视」（扫描局域网找到电视）；也可以接收（从手机导入）。
class SyncSettingsSection extends ConsumerWidget {
  const SyncSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tv = PlatformProfile.isTv;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tv
              ? '在电视上输入服务器地址、密码、Key 很麻烦：打开「接收配置」，用手机扫码填写，或在 Windows 版 Viora 里「发送到电视」，一次把所有配置推过来。'
              : '把这台电脑上的服务器、反向代理、TMDB、弹幕、片头片尾设置一键发送到电视；也可以接收手机或其他电脑发来的配置。',
          style: VText.caption.copyWith(color: VColors.textSecondary),
        ),
        const SizedBox(height: 24),
        if (!tv) ...[
          SettingsEntry(
            title: '发送到电视',
            subtitle: '电视上先打开「设置 → 同步配置 → 接收配置」',
            onConfigure: () => showSendDialog(context, ref),
          ),
          const SizedBox(height: 12),
        ],
        SettingsEntry(
          title: '接收配置',
          subtitle: tv ? '显示二维码：手机扫码填写，或 Windows 发送过来' : '从手机或其他电脑导入（Windows 可能会询问防火墙权限）',
          onConfigure: () => showReceiveDialog(context, ref),
        ),
        if (!tv) ...[
          const SizedBox(height: 12),
          SettingsEntry(
            title: '配置备份',
            subtitle: '导出全部配置到文件（含密码和 Key，请妥善保存）；导入时与现有配置合并',
            trailing: [
              SmallIconButton(icon: Icons.file_upload_outlined, label: '导入', onPressed: () => importBackup(context)),
            ],
            onConfigure: () => exportBackup(ref),
          ),
        ],
        const SizedBox(height: 12),
        const WebDavEntry(),
        const SizedBox(height: 20),
        Text(
          '「发送 / 接收」只在局域网内直接传输，不经过任何外部服务器；接收页面关闭或 5 分钟没有操作后自动停止，需要输入电视上的 4 位配对码。'
          '传输没有加密，请不要在公共 Wi-Fi 下使用。',
          style: VText.small.copyWith(color: VColors.textTertiary),
        ),
      ],
    );
  }
}

// ───────────────────────── WebDAV ─────────────────────────

/// 设置 → 同步配置 → WebDAV 同步：多台设备共用 WebDAV 上的一个配置文件
class WebDavEntry extends ConsumerWidget {
  const WebDavEntry({super.key});

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  Future<void> _run(WebDavSyncMode mode) async {
    final sync = WebDavSync.instance;
    if (sync == null) return;
    try {
      showToast(await sync.sync(mode: mode));
    } catch (e) {
      showToast('$e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(configProvider.select((c) => c.webdav));
    final status = WebDavSync.instance?.status ?? ValueNotifier(const WebDavStatus());
    return ValueListenableBuilder(
      valueListenable: status,
      builder: (context, s, _) => SettingsEntry(
        title: 'WebDAV 同步',
        subtitle: !c.configured
            ? '把全部配置存到 WebDAV（坚果云、群晖、Alist 等），多台设备自动保持一致'
            : [
                Uri.tryParse(c.url)?.host ?? c.url,
                c.autoSync ? '自动同步' : '手动同步',
                if (c.passphrase.isNotEmpty) '已加密',
                if (s.message != null) '${s.at == null ? '' : '${_ago(s.at!)}：'}${s.message}',
              ].join(' · '),
        status: s.running ? '同步中…' : null,
        trailing: [
          if (c.configured) ...[
            SmallIconButton(
              icon: Icons.sync_rounded,
              label: '立即同步',
              onPressed: s.running ? null : () => _run(WebDavSyncMode.auto),
            ),
            SmallIconButton(
              icon: Icons.more_horiz_rounded,
              onPressed: s.running
                  ? null
                  : () => showContextMenu(
                      context,
                      title: 'WebDAV 同步',
                      actions: [
                        MenuAction('用本机配置覆盖云端', Icons.cloud_upload_outlined, () => _run(WebDavSyncMode.upload)),
                        MenuAction('用云端配置覆盖本机', Icons.cloud_download_outlined, () => _run(WebDavSyncMode.download)),
                      ],
                    ),
            ),
          ],
        ],
        onConfigure: () => showWebDavDialog(context, ref),
      ),
    );
  }
}

Future<void> showWebDavDialog(BuildContext context, WidgetRef ref) async {
  final c = ref.read(configProvider).webdav;
  final url = TextEditingController(text: c.url);
  final user = TextEditingController(text: c.username);
  final pass = TextEditingController(text: c.password);
  final path = TextEditingController(text: c.path);
  final phrase = TextEditingController(text: c.passphrase);
  var auto = c.autoSync;
  await showFormDialog(
    context,
    title: 'WebDAV 同步',
    description:
        '服务器、反向代理、播放 UA、TMDB、弹幕、片头片尾设置会存成 WebDAV 上的一个文件，'
        '每台设备填同样的地址即可保持一致。播放内核、缓冲等跟设备有关的设置不同步。'
        '文件里有服务器密码，建议设置加密口令（所有设备填同一个）。',
    saveLabel: '保存并同步',
    children: [
      VTextField(
        label: 'WebDAV 地址',
        controller: url,
        hint: 'https://dav.jianguoyun.com/dav/',
        keyboardType: TextInputType.url,
        autofocus: true,
      ),
      const SizedBox(height: 20),
      Row(
        children: [
          Expanded(
            child: VTextField(label: '用户名', controller: user, credential: true),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: VTextField(label: '密码（坚果云填应用密码）', controller: pass, obscure: true),
          ),
        ],
      ),
      const SizedBox(height: 20),
      Row(
        children: [
          Expanded(
            child: VTextField(label: '文件路径', controller: path, hint: WebDavConfig.defaultPath),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: VTextField(label: '加密口令（可选，所有设备一致）', controller: phrase, obscure: true),
          ),
        ],
      ),
      const SizedBox(height: 20),
      StatefulBuilder(
        builder: (context, setState) => VToggle(
          label: '自动同步',
          subtitle: '启动时同步一次，修改配置后自动上传',
          value: auto,
          onChanged: (v) => setState(() => auto = v),
        ),
      ),
    ],
    onSave: () async {
      final next = WebDavConfig(
        url: url.text.trim(),
        username: user.text.trim(),
        password: pass.text,
        path: path.text.trim().isEmpty ? WebDavConfig.defaultPath : path.text.trim(),
        passphrase: phrase.text,
        autoSync: auto,
      );
      if (next.configured) {
        try {
          await WebDavClient(next).test();
        } catch (e) {
          showToast('$e');
          return false;
        }
      }
      // 换了地址、文件或口令：下一次按第一次同步处理（两边合并），不会误删任何一边的服务器
      if (next.url != c.url || next.path != c.path || next.username != c.username || next.passphrase != c.passphrase) {
        await WebDavSync.instance?.resetState();
      }
      await ref.read(configProvider.notifier).update((x) => x.copyWith(webdav: next));
      if (!next.configured) {
        showToast('已关闭 WebDAV 同步');
        return true;
      }
      unawaited(WebDavSync.instance?.sync().then(showToast, onError: (Object e) => showToast('$e')));
      return true;
    },
  );
  for (final t in [url, user, pass, path, phrase]) {
    t.dispose();
  }
}

// ───────────────────────── 接收 ─────────────────────────

/// 应用收到的配置：合并、保存，然后后台对新增 / 修改的服务器测速并登录
/// 用 [ProviderContainer]（不是 WidgetRef）：接收窗口关掉后，后台登录还要继续
Future<String> applySyncPayload(
  ProviderContainer ref,
  Map<String, dynamic> payload,
  void Function(String) log, {
  bool replaceServers = false,
}) async {
  final store = ref.read(configProvider.notifier);
  final result = mergeSyncPayload(ref.read(configProvider), payload, replaceServers: replaceServers);
  if (result.isEmpty) return '没有可导入的内容';
  await store.update((_) => result.config);
  if (result.segmentKeys.isNotEmpty || result.segmentSettings != null) {
    try {
      final current = await ref.read(segmentSettingsProvider.future);
      await ref.read(segmentSettingsProvider.notifier).save(applySegmentSync(current, result));
    } catch (e) {
      log('片头片尾设置保存失败：$e');
    }
  }
  final message = '已导入：${result.summary.join('、')}';
  log(message);
  for (final id in result.changedServerIds) {
    unawaited(_connect(ref, id, log));
  }
  return message;
}

Future<void> _connect(ProviderContainer ref, String id, void Function(String) log) async {
  final store = ref.read(configProvider.notifier);
  final initial = ref.read(configProvider).server(id);
  if (initial == null) return;
  var server = initial;
  try {
    final config = ref.read(configProvider);
    server = await clientForDraft(config, server).probeAll();
    if (server.lines.every((l) => l.latencyMs == null)) {
      log('「${server.displayName}」连不上，请检查地址或代理');
      await store.upsertServer(server);
      return;
    }
    if (server.name.trim().isEmpty) {
      try {
        final info = await clientForDraft(config, server).publicInfo();
        final name = (info['ServerName'] as String?)?.trim() ?? '';
        if (name.isNotEmpty) server = server.copyWith(name: name);
      } catch (_) {}
    }
    if (!server.loggedIn) server = await clientForDraft(config, server).login();
    await store.upsertServer(server.copyWith(lastAccessAt: DateTime.now()));
    log('「${server.displayName}」已连接');
    Future<void>.delayed(
      const Duration(seconds: 1),
      () => ref.read(indexSyncProvider.notifier).syncServer(id, forceFull: true),
    );
  } catch (e) {
    await store.upsertServer(server);
    log('「${server.displayName}」登录失败：$e');
  }
}

Future<void> showReceiveDialog(BuildContext context, WidgetRef ref) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: '关闭',
  barrierColor: const Color(0xB307080B),
  transitionDuration: VMotion.focus,
  pageBuilder: (context, _, _) => const _ReceiveDialog(),
  transitionBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
);

class _ReceiveDialog extends ConsumerStatefulWidget {
  const _ReceiveDialog();

  @override
  ConsumerState<_ReceiveDialog> createState() => _ReceiveDialogState();
}

class _ReceiveDialogState extends ConsumerState<_ReceiveDialog> {
  ConfigReceiver? _receiver;
  String? _error;
  final _log = <String>[];

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _addLog(String line) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, line);
      if (_log.length > 6) _log.removeLast();
    });
  }

  Future<void> _start() async {
    final container = ProviderScope.containerOf(context, listen: false);
    final config = ref.read(configProvider);
    final name = config.playback.deviceName.trim().isNotEmpty ? config.playback.deviceName.trim() : defaultDeviceName();
    final r = ConfigReceiver(
      deviceName: 'Viora · $name',
      appVersion: appVersion,
      onPayload: (payload, from) async {
        _addLog('收到${from.isEmpty ? '' : '「$from」'}发来的配置');
        final message = await applySyncPayload(container, payload, _addLog);
        showToast(message);
        return message;
      },
    );
    r.changes.addListener(() {
      if (mounted) setState(() {});
    });
    try {
      await r.start();
      if (r.addresses.isEmpty) _error = '没有找到局域网地址：请确认已连接 Wi-Fi 或网线';
    } catch (e) {
      _error = '无法开启接收：$e';
    }
    if (mounted) setState(() => _receiver = r);
  }

  @override
  void dispose() {
    _receiver?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = _receiver;
    final url = r?.url;
    final running = r?.running ?? false;
    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: Glass(
          width: 1240,
          radius: VRadius.panel,
          blur: 40,
          fill: const Color(0xE614161E),
          padding: const EdgeInsets.all(48),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 400,
                height: 400,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(VRadius.md)),
                child: url != null && running
                    ? QrImageView(data: url, padding: EdgeInsets.zero, backgroundColor: Colors.white)
                    : Center(
                        child: Text(
                          _error ?? (r == null ? '正在开启…' : '已停止'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 22, color: Color(0xFF0B0C10)),
                        ),
                      ),
              ),
              const SizedBox(width: 48),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('接收配置', style: VText.h2.copyWith(fontSize: 36)),
                    const SizedBox(height: 20),
                    _step('1', '手机和这台设备连同一个 Wi-Fi，用手机相机扫左边的二维码'),
                    _step('2', '在打开的网页里填写服务器、代理、Key，点「发送到电视」'),
                    _step('3', '或者在 Windows 版 Viora：设置 → 同步配置 → 发送到电视'),
                    const SizedBox(height: 24),
                    if (r != null && running && url != null) ...[
                      Text('配对码', style: VText.caption.copyWith(color: VColors.textTertiary)),
                      Text(
                        r.code,
                        style: const TextStyle(
                          fontSize: 72,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 18,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '地址：${r.addresses.first}:${r.port}'
                        '${r.addresses.length > 1 ? '（其他：${r.addresses.skip(1).take(2).join('、')}）' : ''}',
                        style: VText.label.copyWith(color: VColors.textSecondary),
                      ),
                    ] else if (r?.closedByTimeout ?? false)
                      Text('5 分钟没有操作，已自动停止接收', style: VText.label.copyWith(color: VColors.textSecondary)),
                    const SizedBox(height: 20),
                    for (final line in _log)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('· $line', style: VText.small.copyWith(color: VColors.textSecondary)),
                      ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        PillButton(
                          autofocus: true,
                          icon: Icons.check_rounded,
                          label: '完成',
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        if (r != null && !running) ...[
                          const SizedBox(width: 16),
                          PillButton(
                            icon: Icons.refresh_rounded,
                            label: '重新开始接收',
                            onPressed: () async {
                              r.closedByTimeout = false;
                              await r.start();
                            },
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _step(String n, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: Color(0x29FFFFFF), shape: BoxShape.circle),
          child: Text(n, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 14),
        Expanded(child: Text(text, style: VText.label)),
      ],
    ),
  );
}

// ───────────────────────── 发送（Windows） ─────────────────────────

Future<void> showSendDialog(BuildContext context, WidgetRef ref) async {
  final form = _SendFormController();
  await showFormDialog(
    context,
    title: '发送到电视',
    description: '电视上先打开「设置 → 同步配置 → 接收配置」，再在这里选择电视、输入电视上显示的 4 位配对码。',
    saveLabel: '发送',
    children: [_SendForm(controller: form)],
    onSave: () async {
      final base = form.target != null
          ? Uri(scheme: 'http', host: form.target!.host, port: form.target!.port)
          : ConfigSender.parseAddress(form.address.text);
      if (base == null) {
        showToast('先选择一台电视，或输入电视上显示的地址');
        return false;
      }
      if (!RegExp(r'^\d{4}$').hasMatch(form.code.text.trim())) {
        showToast('请输入电视上显示的 4 位配对码');
        return false;
      }
      if (form.sections.isEmpty) {
        showToast('至少选择一项要发送的内容');
        return false;
      }
      final config = ref.read(configProvider);
      SegmentSettings? segments;
      if (form.sections.contains(SyncSection.segments)) {
        try {
          segments = await ref.read(segmentSettingsProvider.future);
        } catch (_) {}
      }
      final name = config.playback.deviceName.trim().isNotEmpty
          ? config.playback.deviceName.trim()
          : defaultDeviceName();
      final payload = buildSyncPayload(config, sections: form.sections, segments: segments, from: 'Windows · $name');
      try {
        final message = await ConfigSender.send(base, form.code.text, payload);
        showToast('电视$message');
        return true;
      } catch (e) {
        showToast('发送失败：$e');
        return false;
      }
    },
  );
  form.dispose();
}

class _SendFormController {
  final address = TextEditingController();
  final code = TextEditingController();
  SyncTarget? target;
  final sections = {...SyncSection.values};

  void dispose() {
    address.dispose();
    code.dispose();
  }
}

class _SendForm extends StatefulWidget {
  const _SendForm({required this.controller});

  final _SendFormController controller;

  @override
  State<_SendForm> createState() => _SendFormState();
}

class _SendFormState extends State<_SendForm> {
  List<SyncTarget>? _found;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    final found = await ConfigSender.discover();
    if (!mounted) return;
    setState(() {
      _found = found;
      _scanning = false;
      if (found.length == 1) widget.controller.target = found.first;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              _scanning ? '正在查找局域网里的电视…' : '找到 ${_found?.length ?? 0} 台设备',
              style: VText.caption.copyWith(color: VColors.textTertiary),
            ),
            const Spacer(),
            SmallIconButton(icon: Icons.refresh_rounded, label: '重新查找', onPressed: _scanning ? null : _scan),
          ],
        ),
        const SizedBox(height: 12),
        for (final t in _found ?? const <SyncTarget>[]) ...[
          VToggle(
            label: t.name,
            subtitle: '${t.address}${t.version == null ? '' : ' · v${t.version}'}',
            value: identical(c.target, t),
            onChanged: (v) => setState(() => c.target = v ? t : null),
          ),
          const SizedBox(height: 8),
        ],
        if (!_scanning && (_found?.isEmpty ?? true))
          VTextField(label: '没找到时手动输入电视上显示的地址', controller: c.address, hint: '192.168.1.20:8090'),
        const SizedBox(height: 20),
        VTextField(label: '配对码（电视上的 4 位数字）', controller: c.code, autofocus: true, keyboardType: TextInputType.number),
        const SizedBox(height: 20),
        Text('发送内容', style: VText.caption.copyWith(color: VColors.textTertiary)),
        const SizedBox(height: 8),
        for (final s in SyncSection.values) ...[
          VToggle(
            label: s.label,
            subtitle: s.detail,
            value: c.sections.contains(s),
            onChanged: (v) => setState(() => v ? c.sections.add(s) : c.sections.remove(s)),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}
