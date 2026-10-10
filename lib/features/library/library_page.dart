import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../ui/focus/focusable.dart';
import '../../ui/panels/context_menu.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/toast.dart';
import 'library_mock.dart';

/// 资源库（docs/06-ui-design.md §6）：媒体服务器卡片网格。
class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final servers = LibraryMock.servers;
    final movies = servers.fold<int>(0, (a, s) => a + (s.movies ?? 0));
    final series = servers.fold<int>(0, (a, s) => a + (s.series ?? 0));
    return Stack(
      children: [
        const Positioned.fill(child: _Ambient()),
        Positioned.fill(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(VSpace.contentLeft, VSpace.safeV, VSpace.safeH, 160),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('资源库', style: VText.h1),
                    const SizedBox(width: 24),
                    Text(
                      '${servers.length} 台服务器 · 电影 ${formatCount(movies)} · 剧集 ${formatCount(series)}',
                      style: const TextStyle(fontSize: 20, color: VColors.textTertiary),
                    ),
                    const Spacer(),
                    PillButton(icon: Icons.add_rounded, label: '添加服务器', onPressed: () => showToast('添加服务器将在 M1 实现')),
                    const SizedBox(width: 16),
                    PillButton(label: '测速全部', onPressed: () => showToast('正在测速 12 台服务器…')),
                    const SizedBox(width: 16),
                    PillButton(label: '编辑', onPressed: () => showToast('编辑模式将在 M1 实现')),
                  ],
                ),
                const SizedBox(height: 40),
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
                const SizedBox(height: 28),
                const Text(
                  'OK 进入 · 菜单键 / 长按 OK 切换线路、测速、绑定代理、播放 UA、重新同步、删除',
                  style: TextStyle(fontSize: 18, color: VColors.textMuted),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({required this.server, this.autofocus = false});

  final MockServer server;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final s = server;
    final dot = switch (s.status) {
      ServerStatus.ok => VColors.ok,
      ServerStatus.fallback => VColors.warn,
      ServerStatus.down => VColors.bad,
    };
    return VFocusable(
      autofocus: autofocus,
      radius: 24,
      scale: 1.05,
      onFocusChange: (focused) {
        if (focused) Scrollable.ensureVisible(context, alignment: 0.4, duration: VMotion.scroll);
      },
      onActivate: () => showToast('进入「${s.name}」将在 M1 接入 ${s.type} 后可用'),
      onMenu: () => showContextMenu(
        context,
        title: s.name,
        actions: [
          MenuAction('切换线路', Icons.alt_route_rounded, () => showToast('线路切换将在 M1 实现')),
          MenuAction('测速', Icons.speed_rounded, () => showToast('测速中…')),
          MenuAction('绑定代理', Icons.shield_outlined, () => showToast('绑定代理将在 M1 实现')),
          MenuAction('播放 UA', Icons.badge_outlined, () => showToast('自定义 UA 将在 M1 实现')),
          MenuAction('重新同步索引', Icons.sync_rounded, () => showToast('聚合索引将在 M3 实现')),
          MenuAction('删除', Icons.delete_outline_rounded, () => showToast('已删除（演示）')),
        ],
      ),
      builder: (context, focused) => AnimatedContainer(
        duration: VMotion.focus,
        height: 236,
        clipBehavior: Clip.antiAlias,
        padding: const EdgeInsets.fromLTRB(26, 24, 26, 24),
        decoration: BoxDecoration(
          color: focused ? const Color(0x26FFFFFF) : const Color(0x0FFFFFFF),
          borderRadius: BorderRadius.circular(24),
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
                    decoration: BoxDecoration(shape: BoxShape.circle, gradient: s.icon),
                  ),
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        gradient: s.icon,
                        boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 16, offset: Offset(0, 6))],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: const Color(0x1AFFFFFF), borderRadius: BorderRadius.circular(6)),
                      child: Text(
                        s.type,
                        style: const TextStyle(fontSize: 14, letterSpacing: 1, color: Color(0xB3FFFFFF)),
                      ),
                    ),
                    const Spacer(),
                    Text(s.lastAccess, style: const TextStyle(fontSize: 17, color: VColors.textTertiary)),
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
                        s.name,
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
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text('R18', style: TextStyle(fontSize: 14, color: VColors.adult)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Text(s.note, style: const TextStyle(fontSize: 18, color: VColors.textTertiary)),
                const Spacer(),
                Text.rich(
                  TextSpan(
                    style: const TextStyle(fontSize: 18, color: Color(0xBFFFFFFF)),
                    children: [
                      const TextSpan(text: '电影 '),
                      TextSpan(text: s.movies == null ? '—' : formatCount(s.movies!), style: _countStyle),
                      const TextSpan(text: '    剧集 '),
                      TextSpan(text: s.series == null ? '—' : formatCount(s.series!), style: _countStyle),
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
