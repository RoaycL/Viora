import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../glass/glass.dart';

/// 右上角：服务器在线状态 + 时钟。
class StatusBar extends StatefulWidget {
  const StatusBar({super.key, this.online = 12});

  final int online;

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
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
    return Row(
      children: [
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
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: VColors.ok,
                  boxShadow: [BoxShadow(color: VColors.ok, blurRadius: 10)],
                ),
              ),
              const SizedBox(width: 10),
              Text('${widget.online} 台服务器在线', style: const TextStyle(fontSize: 20, color: Color(0xDBFFFFFF))),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Text(
          time,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: Color(0xEBFFFFFF)),
        ),
      ],
    );
  }
}
