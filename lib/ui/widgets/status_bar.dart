import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/config/app_config.dart';
import '../../data/config/config_store.dart';
import '../glass/glass.dart';

/// 服务器在线状态：最近一次测速有线路可达即算在线。全部在线绿、部分在线橙、都不在线红
({int online, int total, Color color}) serverStatusOf(List<ServerConfig> servers) {
  final online = servers.where((s) => s.lines.any((l) => l.latencyMs != null)).length;
  final color = online == servers.length
      ? VColors.ok
      : online == 0
      ? VColors.bad
      : VColors.warn;
  return (online: online, total: servers.length, color: color);
}

/// 时钟文字（时:分），每 15 秒刷新
class ClockText extends StatefulWidget {
  const ClockText({super.key, required this.style});

  final TextStyle style;

  @override
  State<ClockText> createState() => _ClockTextState();
}

class _ClockTextState extends State<ClockText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Text('${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}', style: widget.style);
  }
}

/// 右上角：服务器在线状态（最近一次测速有线路可达即算在线）+ 时钟。
/// 电视用紧凑样式放在顶部标签栏；Windows 的状态和时钟在左侧导航栏里，不再用这个
class StatusBar extends ConsumerStatefulWidget {
  const StatusBar({super.key, this.compact = false});

  /// 紧凑：只有一个小胶囊「状态点 + 时间」（电视顶部标签栏里用，不挤到居中的标签）
  final bool compact;

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
    final timeText = Text(
      time,
      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Color(0xEBFFFFFF)),
    );
    if (widget.compact) {
      return Semantics(
        label: servers.isEmpty ? null : '$online / ${servers.length} 台服务器在线',
        child: Glass(
          radius: 999,
          blur: 20,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (servers.isNotEmpty) ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                    boxShadow: [BoxShadow(color: color, blurRadius: 10)],
                  ),
                ),
                const SizedBox(width: 12),
              ],
              timeText,
            ],
          ),
        ),
      );
    }
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
          const SizedBox(width: 12),
        ],
        // 时间也放在磨砂底上，亮背景图上依然清楚
        Glass(radius: 999, blur: 20, padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8), child: timeText),
      ],
    );
  }
}
