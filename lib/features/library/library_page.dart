import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/desktop_prefs.dart';
import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../../data/config/app_config.dart';
import '../../data/config/config_store.dart';
import '../../data/index/index_sync.dart';
import '../../data/media/server_registry.dart';
import '../../ui/focus/focusable.dart';
import '../../ui/glass/glass.dart';
import '../../ui/panels/context_menu.dart';
import '../../ui/panels/form_dialog.dart';
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
            final n = await client.serverName();
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
                            _DraggableCard(
                              key: ValueKey(servers[i].id),
                              server: servers[i],
                              index: i,
                              indexOf: (id) => servers.indexWhere((s) => s.id == id),
                              width: width,
                              autofocus: i == 0,
                            ),
                        ],
                      );
                    },
                  ),
                if (servers.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  Text(
                    PlatformProfile.isDesktop
                        ? '单击进入 · 右键：测速、切换线路、编辑、删除 · 按住卡片拖动可以调整顺序'
                        : 'OK 进入 · 菜单键 / 长按 OK：测速、切换线路、移动位置、编辑、删除',
                    style: const TextStyle(fontSize: 18, color: VColors.textMuted),
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

/// 按住卡片（鼠标 / 触屏长按）拖到另一张卡片上：挪到那张卡片的位置
class _DraggableCard extends ConsumerStatefulWidget {
  const _DraggableCard({
    super.key,
    required this.server,
    required this.index,
    required this.indexOf,
    required this.width,
    this.autofocus = false,
  });

  final ServerConfig server;
  final int index;
  final int Function(String id) indexOf;
  final double width;
  final bool autofocus;

  @override
  ConsumerState<_DraggableCard> createState() => _DraggableCardState();
}

class _DraggableCardState extends ConsumerState<_DraggableCard> {
  /// 有卡片拖到这张上面（显示插入位置的高亮）
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final card = _ServerCard(server: widget.server, autofocus: widget.autofocus);
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) {
        final ok = d.data != widget.server.id;
        if (ok != _hovering) setState(() => _hovering = ok);
        return ok;
      },
      onLeave: (_) => setState(() => _hovering = false),
      onAcceptWithDetails: (d) {
        setState(() => _hovering = false);
        final from = widget.indexOf(d.data);
        if (from < 0) return;
        // 从前往后拖放到目标后面，从后往前拖放到目标前面：和目标交换到它原来的位置
        ref.read(configProvider.notifier).moveServerTo(d.data, widget.server.id, after: from < widget.index);
      },
      builder: (context, _, _) => SizedBox(
        width: widget.width,
        child: LongPressDraggable<String>(
          data: widget.server.id,
          delay: const Duration(milliseconds: 350),
          hapticFeedbackOnStart: true,
          feedback: Material(
            type: MaterialType.transparency,
            child: SizedBox(
              width: widget.width,
              child: Opacity(
                opacity: 0.9,
                child: Transform.scale(
                  scale: 1.04,
                  child: IgnorePointer(child: _ServerCard(server: widget.server)),
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.3, child: IgnorePointer(child: card)),
          child: AnimatedContainer(
            duration: VMotion.focus,
            // 画在前景上，不改变卡片大小
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(VRadius.panel),
              border: Border.all(color: _hovering ? VColors.accent : const Color(0x00000000), width: 3),
            ),
            child: card,
          ),
        ),
      ),
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
    final visible = ref.read(configProvider).servers;
    final index = visible.indexWhere((s) => s.id == server.id);
    final count = visible.length;
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
          // 二级菜单贴着「切换线路」这一项弹出，不再在鼠标位置另开一个菜单
          MenuAction.submenu(
            '切换线路',
            Icons.alt_route_rounded,
            title: '选择线路',
            items: () {
              final s = ref.read(configProvider).server(server.id) ?? server;
              return [
                MenuAction(
                  '自动（测速最快）${s.activeLineId == null ? '  ✓' : ''}',
                  Icons.auto_awesome_rounded,
                  () => store.updateServer(server.id, (s) => s.copyWith(clearActiveLine: true)),
                ),
                for (final l in s.lines)
                  MenuAction(
                    '${l.name} · ${l.latencyMs == null ? '不可用' : '${l.latencyMs}ms'}'
                    '${s.activeLineId == l.id ? '  ✓' : ''}',
                    Icons.route_rounded,
                    () => store.updateServer(server.id, (s) => s.copyWith(activeLineId: l.id)),
                  ),
              ];
            },
          ),
        MenuAction('编辑', Icons.edit_rounded, () => context.go('/library/edit/${server.id}')),
        // Windows：固定到左侧导航栏，一点就打开这台服务器
        if (PlatformProfile.isDesktop)
          DesktopPrefs.instance.pinnedServers.value.contains(server.id)
              ? MenuAction(
                  '从侧边栏移除',
                  Icons.push_pin_outlined,
                  () => DesktopPrefs.instance.setServerPinned(server.id, false),
                )
              : MenuAction('添加到侧边栏', Icons.push_pin_rounded, () {
                  DesktopPrefs.instance.setServerPinned(server.id, true);
                  showToast('已把「${server.displayName}」添加到左侧导航栏');
                }),
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
        if (index > 0) MenuAction('向前移动', Icons.arrow_back_rounded, () => store.moveServer(server.id, -1)),
        if (index >= 0 && index < count - 1)
          MenuAction('向后移动', Icons.arrow_forward_rounded, () => store.moveServer(server.id, 1)),
        MenuAction('删除', Icons.delete_outline_rounded, () async {
          // 删除后这张卡片会被移除（ref 随之失效）：等待之前先拿到要用的对象
          final index = ref.read(indexSyncProvider.notifier);
          final ok = await showConfirmDialog(
            context,
            title: '删除「${server.displayName}」？',
            message: '会删除这台服务器的登录信息和聚合索引，服务器上的内容和观看记录不受影响。',
            confirmLabel: '删除',
            confirmIcon: Icons.delete_forever_rounded,
            destructive: true,
          );
          if (ok != true) return;
          await store.removeServer(server.id);
          index.forget(server.id);
          await DesktopPrefs.instance.setServerPinned(server.id, false);
          showToast('已删除「${server.displayName}」');
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
              // 电视：实时模糊是弱 GPU 上最贵的操作，用径向渐变画出差不多的光晕
              child: PerfMode.lite
                  ? Transform.translate(
                      offset: const Offset(60, -60),
                      child: Container(
                        width: 300,
                        height: 300,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [icon.colors.last.withValues(alpha: 0.3), icon.colors.last.withValues(alpha: 0)],
                          ),
                        ),
                      ),
                    )
                  : Opacity(
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
    ServerType.plex => const [Color(0xFFF5C04A), Color(0xFFCC7B19)],
    ServerType.fnos => const [Color(0xFF5B8CFF), Color(0xFF1F4FD8)],
  },
);

/// Emby / Jellyfin 官方图标；Plex 画一个琥珀色的箭头、飞牛影视画一个蓝底的"飞"字（不打包它们的商标图）
class ServerTypeLogo extends StatelessWidget {
  const ServerTypeLogo(this.type, {super.key});

  final ServerType type;

  @override
  Widget build(BuildContext context) => switch (type) {
    ServerType.plex => const AspectRatio(aspectRatio: 1, child: CustomPaint(painter: _ChevronPainter())),
    ServerType.fnos => const AspectRatio(aspectRatio: 1, child: CustomPaint(painter: _FnosMarkPainter())),
    ServerType.emby || ServerType.jellyfin => Image.asset(
      type == ServerType.emby ? 'assets/images/emby_logo.png' : 'assets/images/jellyfin_logo.png',
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    ),
  };
}

class _ChevronPainter extends CustomPainter {
  const _ChevronPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.shortestSide;
    final o = Offset((size.width - w) / 2, (size.height - w) / 2);
    final path = Path()
      ..moveTo(o.dx + w * 0.22, o.dy + w * 0.1)
      ..lineTo(o.dx + w * 0.5, o.dy + w * 0.1)
      ..lineTo(o.dx + w * 0.82, o.dy + w * 0.5)
      ..lineTo(o.dx + w * 0.5, o.dy + w * 0.9)
      ..lineTo(o.dx + w * 0.22, o.dy + w * 0.9)
      ..lineTo(o.dx + w * 0.54, o.dy + w * 0.5)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFFE5A00D));
  }

  @override
  bool shouldRepaint(_ChevronPainter oldDelegate) => false;
}

class _FnosMarkPainter extends CustomPainter {
  const _FnosMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.shortestSide;
    final rect = Rect.fromLTWH((size.width - w) / 2, (size.height - w) / 2, w, w).deflate(w * 0.06);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(w * 0.24)),
      Paint()..color = const Color(0xFF2F6BFF),
    );
    final text = TextPainter(
      text: TextSpan(
        text: '飞',
        style: TextStyle(color: Colors.white, fontSize: w * 0.56, fontWeight: FontWeight.w700, height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, rect.center - Offset(text.width / 2, text.height / 2));
  }

  @override
  bool shouldRepaint(_FnosMarkPainter oldDelegate) => false;
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
