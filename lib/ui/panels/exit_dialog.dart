import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../glass/glass.dart';
import '../widgets/buttons.dart';

/// 电视长按返回键 3 秒后的「退出 Viora？」确认。默认焦点在「取消」，误按 OK 也不会退出。
Future<bool> showExitDialog(BuildContext context) async {
  final exit = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '取消',
    barrierColor: const Color(0xB307080B),
    transitionDuration: VMotion.focus,
    // 长按弹出时返回键往往还按着：忽略它的重复事件，否则对话框一出来就被关掉；重新按一下返回才是取消
    pageBuilder: (context, _, _) => Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, e) =>
          e is KeyRepeatEvent && _isBack(e.logicalKey) ? KeyEventResult.handled : KeyEventResult.ignored,
      child: Center(
        child: Material(
          type: MaterialType.transparency,
          child: Glass(
            width: 720,
            radius: VRadius.panel,
            blur: 40,
            fill: const Color(0xE614161E),
            padding: const EdgeInsets.fromLTRB(48, 44, 48, 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('退出 Viora？', style: VText.h2.copyWith(fontSize: 36)),
                const SizedBox(height: 12),
                Text('确定要退出吗？', style: VText.label.copyWith(color: VColors.textSecondary)),
                const SizedBox(height: 36),
                Row(
                  children: [
                    PillButton(autofocus: true, label: '取消', onPressed: () => Navigator.of(context).pop(false)),
                    const SizedBox(width: 20),
                    PillButton(
                      icon: Icons.power_settings_new_rounded,
                      label: '退出',
                      onPressed: () => Navigator.of(context).pop(true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
  );
  return exit ?? false;
}

bool _isBack(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.gameButtonB;
