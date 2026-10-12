import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/net/request_composer.dart';
import '../../app/theme.dart';
import '../../data/config/app_config.dart';
import '../../data/config/config_store.dart';
import '../../data/emby/emby_client.dart';
import '../../data/index/index_sync.dart';
import '../../data/media/server_registry.dart';
import '../../ui/focus/focus_auto_scroll.dart';
import '../../ui/glass/glass.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/form.dart';
import '../../ui/widgets/toast.dart';

/// 添加 / 编辑媒体服务器（Emby / Jellyfin）。
///
/// 多条线路：每行一个地址，可写成 `名称 | 地址`，例如
/// `主线路 | https://emby.example.com` 与 `CF | https://cf.example.com:8443`。
class ServerEditPage extends ConsumerStatefulWidget {
  const ServerEditPage({super.key, this.serverId});

  /// 为空 = 添加
  final String? serverId;

  @override
  ConsumerState<ServerEditPage> createState() => _ServerEditPageState();
}

class _ServerEditPageState extends ConsumerState<ServerEditPage> {
  final _name = TextEditingController();
  final _lines = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _ua = TextEditingController();
  ServerType _type = ServerType.emby;
  bool _proxied = false;

  /// 使用 HTTPS：打开时所有线路用 https://，关闭用 http://（地址里写了协议时开关跟着变）
  bool _https = false;
  bool _adult = false;
  bool _busy = false;
  String? _error;
  ServerConfig? _existing;

  @override
  void initState() {
    super.initState();
    // 地址里有没有内网地址会影响「走反向代理」的说明
    var lan = false;
    _lines.addListener(() {
      if (_hasLanLine != lan && mounted) setState(() => lan = _hasLanLine);
      // 输入或粘贴了带协议的地址：开关跟着地址走
      final scheme = RegExp(r'(?:^|[|\s])(https?)://', caseSensitive: false).firstMatch(_lines.text)?[1]?.toLowerCase();
      if (scheme != null && (scheme == 'https') != _https && mounted) setState(() => _https = scheme == 'https');
    });
    final id = widget.serverId;
    _existing = id == null ? null : ref.read(configProvider).server(id);
    final s = _existing;
    if (s != null) {
      _type = s.type;
      _name.text = s.name;
      // 地址不带协议显示，协议由「使用 HTTPS」开关决定
      _https = s.lines.isNotEmpty && s.lines.first.url.trim().toLowerCase().startsWith('https://');
      _lines.text = s.lines.map((l) => '${l.name} | ${_stripScheme(l.url)}').join('\n');
      _user.text = s.username;
      _pass.text = s.password;
      _ua.text = s.userAgent ?? '';
      _proxied = s.lines.any((l) => l.proxied);
      _adult = s.adult;
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _lines, _user, _pass, _ua]) {
      c.dispose();
    }
    super.dispose();
  }

  List<ServerLine> _parseLines() {
    final old = _existing?.lines ?? const <ServerLine>[];
    final result = <ServerLine>[];
    final raw = _lines.text.split(RegExp(r'[\n;；]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    for (var i = 0; i < raw.length; i++) {
      final parts = raw[i].split('|');
      var name = parts.length > 1 ? parts.first.trim() : (i == 0 ? '主线路' : '线路 ${i + 1}');
      var url = (parts.length > 1 ? parts.sublist(1).join('|') : parts.first).trim();
      // 协议统一由开关决定
      url = '${_https ? 'https' : 'http'}://${_stripScheme(url)}';
      url = url.replaceAll(RegExp(r'/+$'), '');
      if (Uri.tryParse(url)?.host.isEmpty ?? true) throw FormatException('线路地址无效：${raw[i]}');
      if (name.isEmpty) name = '线路 ${i + 1}';
      final prev = old.where((l) => l.url == url).firstOrNull;
      result.add(ServerLine(id: prev?.id ?? newId(), name: name, url: url, proxied: _proxied));
    }
    if (result.isEmpty) throw const FormatException('请至少填写一个服务器地址');
    return result;
  }

  static String _stripScheme(String url) => url.trim().replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');

  /// 填写的地址里有内网地址
  bool get _hasLanLine => _lines.text.split(RegExp(r'[\n;；]')).any((raw) {
    final url = raw.contains('|') ? raw.split('|').last.trim() : raw.trim();
    if (url.isEmpty) return false;
    return isLanHost(Uri.tryParse(url.contains('://') ? url : 'http://$url')?.host ?? '');
  });

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final lines = _parseLines();
      final config = ref.read(configProvider);
      final credentialsChanged =
          _existing == null || _existing!.username != _user.text.trim() || _existing!.password != _pass.text;
      var server = ServerConfig(
        id: _existing?.id ?? newId(),
        type: _type,
        name: _name.text.trim(),
        lines: lines,
        username: _user.text.trim(),
        password: _pass.text,
        userId: credentialsChanged ? null : _existing?.userId,
        token: credentialsChanged ? null : _existing?.token,
        userAgent: _ua.text.trim().isEmpty ? null : _ua.text.trim(),
        adult: _adult,
        lastAccessAt: DateTime.now(),
      );
      final client = clientForDraft(config, server);
      server = await client.probeAll();
      if (server.lines.every((l) => l.latencyMs == null)) {
        throw const MediaServerException('所有线路都连不上，请检查地址、端口或代理设置');
      }
      // 读不到服务器名不影响添加（按 UA 拦截的服务器在登录时会说明原因）
      final info = await client.publicInfo().catchError((_) => <String, dynamic>{});
      // Emby 可能返回空的 ServerName：再退到地址的主机名
      final serverName = (info['ServerName'] as String?)?.trim() ?? '';
      if (server.name.trim().isEmpty) {
        server = server.copyWith(name: serverName.isNotEmpty ? serverName : server.displayName);
      }
      if (!server.loggedIn) server = await client.login();
      try {
        final c = await clientForDraft(config, server).counts();
        server = server.copyWith(movieCount: c.movies, seriesCount: c.series);
      } catch (_) {}
      await ref.read(configProvider.notifier).upsertServer(server);
      // 新服务器 / 修改后重建这台服务器的聚合索引（后台进行）
      final id = server.id;
      Future<void>.delayed(
        const Duration(milliseconds: 500),
        () => ref.read(indexSyncProvider.notifier).syncServer(id, forceFull: true),
      );
      showToast('已保存「${server.name}」');
      if (mounted) context.go('/library');
    } catch (e) {
      setState(() => _error = e is FormatException ? e.message : e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = _existing != null;
    return FocusAutoScroll(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(VSpace.contentLeft, VSpace.safeV, VSpace.safeH, 200),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(editing ? '编辑服务器' : '添加服务器', style: VText.h1),
            const SizedBox(height: 32),
            Glass(
              padding: const EdgeInsets.all(44),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  VChoice<ServerType>(
                    label: '服务器类型',
                    options: [for (final t in ServerType.values) (t, t.label)],
                    value: _type,
                    onChanged: editing ? (_) {} : (t) => setState(() => _type = t),
                  ),
                  const SizedBox(height: 28),
                  VTextField(
                    label: '服务器地址（多条线路换行或用分号分隔，可写成"名称 | 地址"）',
                    controller: _lines,
                    autofocus: !editing,
                    hint: _https ? 'emby.example.com:8920' : '192.168.1.10:8096',
                    keyboardType: TextInputType.url,
                    helper: 'Emby 会自动补 /emby 路径；端口按地址里写的（Emby 默认 HTTP 8096 / HTTPS 8920）',
                  ),
                  const SizedBox(height: 16),
                  VToggle(
                    label: '使用 HTTPS',
                    subtitle: _https ? '所有线路使用 https://（外网域名、反代通常用这个）' : '所有线路使用 http://（内网地址通常用这个）',
                    value: _https,
                    onChanged: (v) => setState(() => _https = v),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: VTextField(label: '用户名', controller: _user, credential: true),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: VTextField(label: '密码', controller: _pass, obscure: true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: VTextField(label: '显示名称（可留空，自动读取服务器名）', controller: _name),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: VTextField(label: 'UA（留空使用全局设置；填了登录、浏览、播放都用它）', controller: _ua, credential: true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  VToggle(
                    label: '线路走反向代理',
                    subtitle: _hasLanLine
                        ? '内网地址（如 192.168.x.x）会自动直连，不经过反向代理；需要先在「设置 → 接口与网络」填写完整地址'
                        : '需要先在「设置 → 接口与网络」填写完整地址',
                    value: _proxied,
                    onChanged: (v) => setState(() => _proxied = v),
                  ),
                  const SizedBox(height: 12),
                  VToggle(label: '成人内容（R18）', value: _adult, onChanged: (v) => setState(() => _adult = v)),
                  const SizedBox(height: 32),
                  if (_error != null) ...[
                    Text(_error!, style: VText.label.copyWith(color: VColors.bad)),
                    const SizedBox(height: 20),
                  ],
                  Row(
                    children: [
                      PillButton(
                        large: true,
                        icon: _busy ? Icons.hourglass_top_rounded : Icons.login_rounded,
                        label: _busy ? '正在连接…' : (editing ? '保存并重新连接' : '连接并登录'),
                        onPressed: _busy ? null : _save,
                      ),
                      const SizedBox(width: 40),
                      PillButton(label: '取消', onPressed: () => context.go('/library')),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
