import 'dart:async';

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
import '../../ui/panels/form_dialog.dart' show SmallIconButton;
import 'library_page.dart' show ServerTypeLogo;

/// 添加 / 编辑媒体服务器（Emby / Jellyfin / Plex）。
///
/// 多条线路：每条线路一行，「线路名称」和「地址」分两个输入框；第一条是主线路，下面可以添加备用线路。
/// 地址框里仍然可以粘贴 `名称 | 地址` 或多行地址，保存时自动拆开。
class ServerEditPage extends ConsumerStatefulWidget {
  const ServerEditPage({super.key, this.serverId});

  /// 为空 = 添加
  final String? serverId;

  @override
  ConsumerState<ServerEditPage> createState() => _ServerEditPageState();
}

class _ServerEditPageState extends ConsumerState<ServerEditPage> {
  final _name = TextEditingController();
  final _lineDrafts = <_LineDraft>[];
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

  /// plex.tv/link 授权码（正在等用户输入时显示）
  String? _pinCode;
  Timer? _pinTimer;

  /// 每次重新获取授权码加 1：之前那次还没返回的结果直接丢掉
  int _pinAttempt = 0;

  @override
  void initState() {
    super.initState();
    final id = widget.serverId;
    _existing = id == null ? null : ref.read(configProvider).server(id);
    final s = _existing;
    if (s != null) {
      _type = s.type;
      _name.text = s.name;
      // 地址不带协议显示，协议由「使用 HTTPS」开关决定
      _https = s.lines.isNotEmpty && s.lines.first.url.trim().toLowerCase().startsWith('https://');
      for (final l in s.lines) {
        _addLine(name: l.name, url: _stripScheme(l.url));
      }
      _user.text = s.username;
      _pass.text = s.password;
      _ua.text = s.userAgent ?? '';
      _proxied = s.lines.any((l) => l.proxied);
      _adult = s.adult;
    }
    if (_lineDrafts.isEmpty) _addLine();
  }

  bool _lan = false;

  void _addLine({String name = '', String url = ''}) {
    final d = _LineDraft(name: name, url: url);
    // 地址里有没有内网地址会影响「走反向代理」的说明
    d.url.addListener(() {
      if (!mounted) return;
      if (_hasLanLine != _lan) setState(() => _lan = _hasLanLine);
      // 输入或粘贴了带协议的地址：开关跟着地址走
      final scheme = RegExp(r'(?:^|[|\s])(https?)://', caseSensitive: false).firstMatch(d.url.text)?[1]?.toLowerCase();
      if (scheme != null && (scheme == 'https') != _https) setState(() => _https = scheme == 'https');
    });
    _lineDrafts.add(d);
  }

  void _removeLine(int i) {
    final d = _lineDrafts.removeAt(i);
    WidgetsBinding.instance.addPostFrameCallback((_) => d.dispose());
    setState(() => _lan = _hasLanLine);
  }

  /// 每条线路的 (名称, 地址)：地址框里粘贴了多行或「名称 | 地址」时拆开
  List<(String, String)> get _rawLines => [
    for (final d in _lineDrafts)
      for (final (j, raw)
          in d.url.text.split(RegExp(r'[\n;；]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).indexed)
        if (raw.contains('|'))
          (raw.split('|').first.trim(), raw.split('|').sublist(1).join('|').trim())
        else
          (j == 0 ? d.name.text.trim() : '', raw),
  ];

  @override
  void dispose() {
    _pinAttempt++;
    _pinTimer?.cancel();
    for (final c in [_name, _user, _pass, _ua]) {
      c.dispose();
    }
    for (final d in _lineDrafts) {
      d.dispose();
    }
    super.dispose();
  }

  List<ServerLine> _parseLines() {
    final old = _existing?.lines ?? const <ServerLine>[];
    final result = <ServerLine>[];
    final raw = _rawLines;
    for (var i = 0; i < raw.length; i++) {
      var (name, url) = raw[i];
      // 协议统一由开关决定
      url = '${_https ? 'https' : 'http'}://${_stripScheme(url)}';
      url = url.replaceAll(RegExp(r'/+$'), '');
      if (Uri.tryParse(url)?.host.isEmpty ?? true) throw FormatException('线路地址无效：${raw[i].$2}');
      if (name.isEmpty) name = i == 0 ? '主线路' : '线路 ${i + 1}';
      final prev = old.where((l) => l.url == url).firstOrNull;
      result.add(ServerLine(id: prev?.id ?? newId(), name: name, url: url, proxied: _proxied));
    }
    if (result.isEmpty) throw const FormatException('请至少填写一个服务器地址');
    return result;
  }

  static String _stripScheme(String url) => url.trim().replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');

  /// 填写的地址里有内网地址
  bool get _hasLanLine => _rawLines.any((l) {
    final url = l.$2;
    return isLanHost(Uri.tryParse(url.contains('://') ? url : 'http://$url')?.host ?? '');
  });

  /// Plex：申请授权码，用户在手机 / 电脑上打开 plex.tv/link 输入后拿到账号令牌，填进密码框（用户名留空）并保存
  Future<void> _startPlexPin() async {
    _pinTimer?.cancel();
    final attempt = ++_pinAttempt;
    bool stale() => !mounted || attempt != _pinAttempt;
    setState(() {
      _error = null;
      _pinCode = null;
    });
    final config = ref.read(configProvider);
    try {
      final pin = await PlexClient.createPin(config, appVersion);
      if (stale()) return;
      setState(() => _pinCode = pin.code);
      final started = DateTime.now();
      var checking = false;
      _pinTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
        if (stale()) {
          t.cancel();
          return;
        }
        if (checking) return;
        if (DateTime.now().difference(started) > const Duration(minutes: 10)) {
          t.cancel();
          if (mounted) setState(() => _pinCode = null);
          return;
        }
        checking = true;
        try {
          final token = await PlexClient.checkPin(config, appVersion, pin.id);
          if (token == null || stale()) return;
          t.cancel();
          setState(() {
            _pinCode = null;
            _user.clear();
            _pass.text = token;
          });
          showToast('plex.tv 授权成功');
          if (_rawLines.isNotEmpty) unawaited(_save());
        } catch (e) {
          t.cancel();
          if (!stale()) {
            setState(() {
              _pinCode = null;
              _error = e.toString();
            });
          }
        } finally {
          checking = false;
        }
      });
    } catch (e) {
      if (!stale()) setState(() => _error = e.toString());
    }
  }

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
      if (!server.loggedIn) server = await client.login();
      // 显示名称留空：登录后读服务器名（登录后才能读到的也能拿到，如 Plex、拦截免登录接口的 Emby）。
      // 读不到就保持空：卡片上暂时显示主机名，之后资源库测速时还会再补，不把主机名写死成名称
      if (server.name.trim().isEmpty) {
        final serverName = await clientForDraft(config, server).serverName();
        if (serverName.isNotEmpty) server = server.copyWith(name: serverName);
      }
      try {
        final c = await clientForDraft(config, server).counts();
        server = server.copyWith(movieCount: c.movies, seriesCount: c.series);
      } catch (_) {}
      await ref.read(configProvider.notifier).upsertServer(server);
      // 上面测速至少有一条线路连得上：立即算作可用（编辑页用的是草稿客户端，不会自动更新可用状态）
      ref
          .read(serverReachabilityProvider.notifier)
          .record(server.id, ref.read(configProvider).clientKey(server.id), true, manual: true);
      // 新服务器 / 修改后重建这台服务器的聚合索引（后台进行）
      final id = server.id;
      Future<void>.delayed(
        const Duration(milliseconds: 500),
        () => ref.read(indexSyncProvider.notifier).syncServer(id, forceFull: true),
      );
      showToast('已保存「${server.displayName}」');
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
        padding: EdgeInsets.fromLTRB(VSpace.contentLeft, VSpace.pageTop, VSpace.safeH, 200),
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
                    leading: (t) => ServerTypeLogo(t),
                    value: _type,
                    onChanged: editing
                        ? (_) {}
                        : (t) => setState(() {
                            // 离开 Plex：作废还在等的 plex.tv 授权，免得它改掉其他类型服务器的账号密码并自动保存
                            if (t != ServerType.plex) {
                              _pinAttempt++;
                              _pinTimer?.cancel();
                              _pinCode = null;
                            }
                            _type = t;
                          }),
                  ),
                  const SizedBox(height: 28),
                  for (var i = 0; i < _lineDrafts.length; i++) ...[
                    if (i > 0) const SizedBox(height: 16),
                    _LineRow(
                      key: ObjectKey(_lineDrafts[i]),
                      draft: _lineDrafts[i],
                      primary: i == 0,
                      index: i,
                      autofocus: !editing && i == 0,
                      hint: switch (_type) {
                        ServerType.plex => _https ? 'plex.example.com:443' : '192.168.1.10:32400',
                        ServerType.fnos => _https ? 'nas.example.com:5667' : '192.168.1.10:5666',
                        _ => _https ? 'emby.example.com:8920' : '192.168.1.10:8096',
                      },
                      onRemove: i == 0 ? null : () => _removeLine(i),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      PillButton(icon: Icons.add_rounded, label: '添加备用线路', onPressed: () => setState(() => _addLine())),
                      const SizedBox(width: 20),
                      Flexible(
                        child: Text(switch (_type) {
                          ServerType.plex => '填 Plex 服务器自己的地址（默认端口 32400）',
                          ServerType.fnos => '填飞牛 NAS 的地址（默认 HTTP 5666 / HTTPS 5667），和网页端打开飞牛影视的地址一样，不用加 /v',
                          _ => 'Emby 会自动补 /emby 路径；端口按地址里写的（Emby 默认 HTTP 8096 / HTTPS 8920）',
                        }, style: VText.small.copyWith(color: VColors.textMuted)),
                      ),
                    ],
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
                        child: VTextField(
                          label: switch (_type) {
                            ServerType.plex => 'Plex 账号（邮箱或用户名）',
                            ServerType.fnos => '飞牛账号',
                            _ => '用户名',
                          },
                          controller: _user,
                          credential: true,
                        ),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: VTextField(
                          label: '密码',
                          controller: _pass,
                          obscure: true,
                          helper: _type == ServerType.plex
                              ? '开了两步验证：密码后面直接接上 6 位验证码。账号留空时这里填 X-Plex-Token'
                              : (editing && (_existing?.password.isEmpty ?? false)
                                    ? '这台服务器保存的密码是空的（添加时没填密码，服务器允许空密码登录）；有密码的话填上再保存'
                                    : null),
                        ),
                      ),
                    ],
                  ),
                  if (_type == ServerType.plex) ...[
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        PillButton(
                          icon: Icons.link_rounded,
                          label: _pinCode == null ? '用 plex.tv/link 授权登录' : '重新获取授权码',
                          onPressed: _busy ? null : _startPlexPin,
                        ),
                        if (_pinCode != null) ...[
                          const SizedBox(width: 28),
                          Flexible(
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  const TextSpan(text: '在手机或电脑上打开 plex.tv/link，输入  '),
                                  TextSpan(
                                    text: _pinCode,
                                    style: VText.h1.copyWith(letterSpacing: 6, color: const Color(0xFFE5A00D)),
                                  ),
                                ],
                              ),
                              style: VText.label,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
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

/// 一条线路的输入：名称 + 地址
class _LineDraft {
  _LineDraft({String name = '', String url = ''})
    : name = TextEditingController(text: name),
      url = TextEditingController(text: url);

  final TextEditingController name;
  final TextEditingController url;

  void dispose() {
    name.dispose();
    url.dispose();
  }
}

/// 线路一行：左边线路名称（显示在资源库卡片上），右边地址；备用线路右边有删除按钮
class _LineRow extends StatelessWidget {
  const _LineRow({
    super.key,
    required this.draft,
    required this.primary,
    required this.index,
    required this.hint,
    this.autofocus = false,
    this.onRemove,
  });

  final _LineDraft draft;
  final bool primary;
  final int index;
  final String hint;
  final bool autofocus;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        SizedBox(
          width: 300,
          child: VTextField(
            label: primary ? '主线路名称' : '备用线路名称',
            controller: draft.name,
            hint: primary ? '主线路' : '线路 ${index + 1}',
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: VTextField(
            label: primary ? '服务器地址' : '备用线路地址',
            controller: draft.url,
            autofocus: autofocus,
            hint: hint,
            keyboardType: TextInputType.url,
          ),
        ),
        if (onRemove != null) ...[
          const SizedBox(width: 12),
          SmallIconButton(icon: Icons.close_rounded, semanticLabel: '删除这条线路', onPressed: onRemove),
        ],
      ],
    );
  }
}
