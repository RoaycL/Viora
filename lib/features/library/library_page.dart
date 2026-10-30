import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/config/app_config.dart';
import '../../data/config/config_store.dart';
import '../../data/index/index_sync.dart';
import '../../data/media/server_registry.dart';
import '../../ui/focus/focusable.dart';
import '../../ui/glass/glass.dart';
import '../../ui/panels/context_menu.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/cached_image.dart';
import '../../ui/widgets/toast.dart';
import '../../ui/focus/input_mode.dart';

/// 本次运行中是否已经对所有服务器测过速
bool _probedThisSession = false;

/// 资源库（docs/06-ui-design.md §6）：媒体服务器卡片网格。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    if (!_probedThisSession) {
      _probedThisSession = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _probeAll(silent: true));
    }
  }

  Future<void> _probeAll({bool silent = false}) async {
    final servers = ref.read(configProvider).servers;
    if (servers.isEmpty) return;
    if (mounted) setState(() => _probing = true);
    if (!silent) showToast('正在测速 ${servers.length} 台服务器…');
    await Future.wait(
      servers.map((s) async {
        final client = ref.read(serverClientProvider(s.id));
        if (client == null) return;
        await client.probeAll();
        // 早期添加的服务器可能没有名称：补上服务器自己报的名称
        if (s.name.trim().isEmpty) {
          try {
            final n = ((await client.publicInfo())['ServerName'] as String?)?.trim() ?? '';
            if (n.isNotEmpty) {
              await ref.read(configProvider.notifier).updateServer(s.id, (old) => old.copyWith(name: n));
            }
          } catch (_) {}
        }
        try {
          final c = await client.counts();
          await ref
              .read(configProvider.notifier)
              .updateServer(s.id, (old) => old.copyWith(movieCount: c.movies, seriesCount: c.series));
        } catch (_) {}
      }),
    );
    if (mounted) setState(() => _probing = false);
    if (!silent) showToast('测速完成');
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(configProvider.select((c) => c.servers));
    final movies = servers.fold<int>(0, (a, s) => a + (s.movieCount ?? 0));
    final series = servers.fold<int>(0, (a, s) => a + (s.seriesCount ?? 0));
    return Stack(
      children: [
        const Positioned.fill(child: _Ambient()),
        Positioned.fill(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(VSpace.contentLeft, VSpace.pageTop, VSpace.safeH, 160),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('资源库', style: VText.h1),
                    const SizedBox(width: 24),
                    if (servers.isNotEmpty)
                      Text(
                        '${servers.length} 台服务器 · 电影 ${formatCount(movies)} · 剧集 ${formatCount(series)}',
                        style: const TextStyle(fontSize: 20, color: VColors.textTertiary),
                      ),
                    const Spacer(),
                    PillButton(
                      autofocus: servers.isEmpty,
                      icon: Icons.add_rounded,
                      label: '添加服务器',
                      onPressed: () => context.go('/library/add'),
                    ),
                    if (servers.isNotEmpty) ...[
                      const SizedBox(width: 16),
                      PillButton(label: _probing ? '测速中…' : '测速全部', onPressed: _probing ? null : _probeAll),
                    ],
                  ],
                ),
                const SizedBox(height: 40),
                if (servers.isEmpty)
                  const _EmptyState()
                else
                  LayoutBuilder(
                    builder: (context, constraints) {
                      const columns = 4;
                      const gap = 28.0;
                      final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
                      return Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        children: [
                          for (var i = 0; i < servers.length; i++)
                            SizedBox(
                              width: width,
                              child: _ServerCard(server: servers[i], autofocus: i == 0),
                            ),
                        ],
                      );
                    },
                  ),
                if (servers.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  const Text(
                    'OK 进入 · 菜单键 / 长按 OK：测速、切换线路、编辑、重新登录、删除',
                    style: TextStyle(fontSize: 18, color: VColors.textMuted),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Glass(
      width: 1000,
      padding: const EdgeInsets.all(44),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('还没有媒体服务器', style: VText.h2.copyWith(fontSize: 32)),
          const SizedBox(height: 16),
          Text(
            '添加 Emby 或 Jellyfin 服务器后，就能在这里浏览媒体库并播放。'
            '一台服务器可以填写多条线路，Viora 会自动测速选择最快的一条。',
            style: VText.body.copyWith(color: VColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

enum _Status { ok, fallback, down, unknown }

class _ServerCard extends ConsumerWidget {
  const _ServerCard({required this.server, this.autofocus = false});

  final ServerConfig server;
  final bool autofocus;

  _Status get _status {
    final lines = server.lines;
    if (lines.every((l) => l.latencyMs == null)) return lines.isEmpty ? _Status.down : _Status.unknown;
    final active = lines.where((l) => l.id == server.activeLineId).firstOrNull ?? lines.first;
    return active.latencyMs != null ? _Status.ok : _Status.fallback;
  }

  String get _note {
    final reachable = server.lines.where((l) => l.latencyMs != null).toList()
      ..sort((a, b) => a.latencyMs!.compareTo(b.latencyMs!));
    final line = server.lines.where((l) => l.id == server.activeLineId).firstOrNull ?? reachable.firstOrNull;
    if (line == null) return server.lines.length > 1 ? '${server.lines.length} 条线路 · 未连通' : '未连通';
    final parts = [
      line.name,
      line.proxied ? '代理' : '直连',
      if (line.latencyMs != null) '${line.latencyMs}ms',
      if (server.activeLineId == null && server.lines.length > 1) '自动',
    ];
    return parts.join(' · ');
  }

  Future<void> _menu(BuildContext context, WidgetRef ref) {
    final store = ref.read(configProvider.notifier);
    return showContextMenu(
      context,
      title: server.displayName,
      actions: [
        MenuAction('测速', Icons.speed_rounded, () async {
          showToast('正在测速…');
          final s = await ref.read(serverClientProvider(server.id))?.probeAll();
          final ok = s?.lines.where((l) => l.latencyMs != null).length ?? 0;
          showToast('测速完成：$ok / ${server.lines.length} 条线路可用');
        }),
        if (server.lines.length > 1)
          MenuAction('切换线路', Icons.alt_route_rounded, () {
            showContextMenu(
              context,
              title: '选择线路',
              actions: [
                MenuAction(
                  '自动（测速最快）${server.activeLineId == null ? '  ✓' : ''}',
                  Icons.auto_awesome_rounded,
                  () => store.updateServer(server.id, (s) => s.copyWith(clearActiveLine: true)),
                ),
                for (final l in server.lines)
                  MenuAction(
                    '${l.name} · ${l.latencyMs == null ? '不可用' : '${l.latencyMs}ms'}'
                    '${server.activeLineId == l.id ? '  ✓' : ''}',
                    Icons.route_rounded,
                    () => store.updateServer(server.id, (s) => s.copyWith(activeLineId: l.id)),
                  ),
              ],
            );
          }),
        MenuAction('编辑', Icons.edit_rounded, () => context.go('/library/edit/${server.id}')),
        MenuAction('重新同步索引', Icons.sync_rounded, () {
          showToast('正在重建「${server.displayName}」的索引…');
          ref.read(indexSyncProvider.notifier).syncServer(server.id, forceFull: true);
        }),
        MenuAction('重新登录', Icons.login_rounded, () async {
          try {
            await ref.read(serverClientProvider(server.id))?.login();
            showToast('登录成功');
          } catch (e) {
            showToast('登录失败：$e');
          }
        }),
        MenuAction('删除', Icons.delete_outline_rounded, () {
          showContextMenu(
            context,
            title: '删除「${server.displayName}」？',
            actions: [
              MenuAction('确认删除', Icons.delete_forever_rounded, () {
                store.removeServer(server.id);
                ref.read(indexSyncProvider.notifier).forget(server.id);
                showToast('已删除「${server.displayName}」');
              }),
              MenuAction('取消', Icons.close_rounded, () {}),
            ],
          );
        }),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = server;
    final sync = ref.watch(indexSyncProvider.select((m) => m[s.id]));
    final dot = switch (_status) {
      _Status.ok => VColors.ok,
      _Status.fallback => VColors.warn,
      _Status.down => VColors.bad,
      _Status.unknown => VColors.textMuted,
    };
    final icon = _typeGradient(s.type);
    return VFocusable(
      autofocus: autofocus,
      radius: VRadius.panel,
      scale: 1.05,
      onFocusChange: (focused) {
        if (focused && InputMode.shouldAutoScroll) {
          Scrollable.ensureVisible(context, alignment: 0.4, duration: VMotion.scroll);
        }
      },
      onActivate: () {
        ref.read(configProvider.notifier).updateServer(s.id, (old) => old.copyWith(lastAccessAt: DateTime.now()));
        context.go('/library/server/${s.id}');
      },
      onMenu: () => _menu(context, ref),
      builder: (context, focused) => AnimatedContainer(
        duration: VMotion.focus,
        height: 236,
        clipBehavior: Clip.antiAlias,
        padding: const EdgeInsets.fromLTRB(26, 24, 26, 24),
        decoration: BoxDecoration(
          color: focused ? const Color(0x26FFFFFF) : const Color(0x0FFFFFFF),
          borderRadius: BorderRadius.circular(VRadius.panel),
          border: Border.all(color: const Color(0x1AFFFFFF)),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // 图标颜色的微光
            Positioned(
              right: -66,
              top: -64,
              child: Opacity(
                opacity: 0.35,
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                  child: Container(
                    width: 180,
                    height: 180,
                    decoration: BoxDecoration(shape: BoxShape.circle, gradient: icon),
                  ),
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 用户头像；取不到时显示服务器类型（Emby / Jellyfin）的图标
                    Container(
                      width: 52,
                      height: 52,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(VRadius.md),
                        color: const Color(0xFF1C1F27),
                        boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 16, offset: Offset(0, 6))],
                      ),
                      child: _UserAvatar(
                        serverId: s.id,
                        fallback: Padding(padding: const EdgeInsets.all(9), child: ServerTypeLogo(s.type)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0x1AFFFFFF),
                        borderRadius: BorderRadius.circular(VRadius.xs),
                      ),
                      child: Text(
                        s.type.label.toUpperCase(),
                        style: const TextStyle(fontSize: 14, letterSpacing: 1, color: Color(0xB3FFFFFF)),
                      ),
                    ),
                    const Spacer(),
                    Text(_ago(s.lastAccessAt), style: const TextStyle(fontSize: 17, color: VColors.textTertiary)),
                    const SizedBox(width: 10),
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: dot,
                        boxShadow: [BoxShadow(color: dot, blurRadius: 10)],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        s.displayName,
                        style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (s.adult) ...[
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          border: Border.all(color: const Color(0x99FF788C)),
                          borderRadius: BorderRadius.circular(VRadius.xs),
                        ),
                        child: const Text('R18', style: TextStyle(fontSize: 14, color: VColors.adult)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _note,
                  style: const TextStyle(fontSize: 18, color: VColors.textTertiary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const Spacer(),
                if (sync?.running == true)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      sync!.total == null ? '正在同步索引…' : '正在同步索引 ${sync.done} / ${sync.total}',
                      style: const TextStyle(fontSize: 16, color: VColors.accent),
                    ),
                  ),
                Text.rich(
                  TextSpan(
                    style: const TextStyle(fontSize: 18, color: Color(0xBFFFFFFF)),
                    children: [
                      const TextSpan(text: '电影 '),
                      TextSpan(text: s.movieCount == null ? '—' : formatCount(s.movieCount!), style: _countStyle),
                      const TextSpan(text: '    剧集 '),
                      TextSpan(text: s.seriesCount == null ? '—' : formatCount(s.seriesCount!), style: _countStyle),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

const _countStyle = TextStyle(fontWeight: FontWeight.w600, color: Colors.white);

/// 卡片光晕颜色：跟随服务器类型的品牌色
LinearGradient _typeGradient(ServerType type) => LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: switch (type) {
    ServerType.emby => const [Color(0xFF7EE07A), Color(0xFF2E8B2A)],
    ServerType.jellyfin => const [Color(0xFFAA5CC3), Color(0xFF00A4DC)],
  },
);

/// Emby / Jellyfin 官方图标
class ServerTypeLogo extends StatelessWidget {
  const ServerTypeLogo(this.type, {super.key});

  final ServerType type;

  @override
  Widget build(BuildContext context) => Image.asset(
    switch (type) {
      ServerType.emby => 'assets/images/emby_logo.png',
      ServerType.jellyfin => 'assets/images/jellyfin_logo.png',
    },
    fit: BoxFit.contain,
    filterQuality: FilterQuality.medium,
  );
}

String _ago(DateTime? t) {
  if (t == null) return '';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前';
  if (d.inDays < 1) return '${d.inHours} 小时前';
  return '${d.inDays} 天前';
}

class _Ambient extends StatelessWidget {
  const _Ambient();

  @override
  Widget build(BuildContext context) {
    return const Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0.7, -1),
              radius: 0.9,
              colors: [Color(0x59788CFF), Color(0x00788CFF)],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(-0.6, 1),
              radius: 0.8,
              colors: [Color(0x2EFF8CBE), Color(0x00FF8CBE)],
            ),
          ),
        ),
      ],
    );
  }
}

String formatCount(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

/// 服务器上当前用户的头像
class _UserAvatar extends ConsumerWidget {
  const _UserAvatar({required this.serverId, required this.fallback});

  final String serverId;
  final Widget fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final req = ref.watch(serverClientProvider(serverId))?.userImage(maxWidth: 160);
    if (req == null) return fallback;
    return Image(
      image: netImage(req.url.toString(), headers: req.headers, cacheWidth: 160),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, sync) => frame == null && !sync ? fallback : child,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}
