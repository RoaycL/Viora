import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/config/config_store.dart';
import '../glass/glass.dart';

/// 右上角：服务器在线状态（最近一次测速有线路可达即算在线）+ 时钟。
class StatusBar extends ConsumerStatefulWidget {
  const StatusBar({super.key});

  @override
  ConsumerState<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends ConsumerState<StatusBar> {
  late Timer _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => setState(() => _now = DateTime.now()));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final time = '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';
    final servers = ref.watch(configProvider.select((c) => c.servers));
    final online = servers.where((s) => s.lines.any((l) => l.latencyMs != null)).length;
    final color = online == servers.length
        ? VColors.ok
        : online == 0
        ? VColors.bad
        : VColors.warn;
    // mainAxisSize.min：放在 Align 里也贴着右边，不会被撑开跑到左边
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (servers.isNotEmpty) ...[
          Glass(
            radius: 999,
            blur: 20,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                    boxShadow: [BoxShadow(color: color, blurRadius: 10)],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  online == servers.length ? '${servers.length} 台服务器在线' : '$online / ${servers.length} 台服务器在线',
                  style: const TextStyle(fontSize: 20, color: Color(0xDBFFFFFF)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
        ],
        Text(
          time,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: Color(0xEBFFFFFF)),
        ),
      ],
    );
  }
}
