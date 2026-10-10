import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../focus/focusable.dart';
import '../glass/glass.dart';

class MenuAction {
  const MenuAction(this.label, this.icon, this.onSelected);

  final String label;
  final IconData icon;
  final VoidCallback onSelected;
}

/// 上下文菜单：从右侧滑入的磨砂玻璃面板（docs/07-input-control.md §3.4）。
/// ↑↓ 选择，OK 执行，返回 / ← 关闭。
Future<void> showContextMenu(BuildContext context, {required String title, required List<MenuAction> actions}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭菜单',
    barrierColor: const Color(0x6607080B),
    transitionDuration: VMotion.scroll,
    pageBuilder: (context, _, _) => _ContextMenuPanel(title: title, actions: actions),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return SlideTransition(
        position: Tween(begin: const Offset(0.3, 0), end: Offset.zero).animate(curved),
        child: FadeTransition(opacity: curved, child: child),
      );
    },
  );
}

class _ContextMenuPanel extends StatelessWidget {
  const _ContextMenuPanel({required this.title, required this.actions});

  final String title;
  final List<MenuAction> actions;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Glass(
          width: 560,
          radius: 32,
          blur: 40,
          fill: const Color(0x8C12141C),
          padding: const EdgeInsets.fromLTRB(32, 36, 32, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: VText.h2.copyWith(fontSize: 30), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 20),
              for (var i = 0; i < actions.length; i++) ...[
                VFocusable(
                  autofocus: i == 0,
                  radius: 18,
                  scale: 1.02,
                  showRing: false,
                  onActivate: () {
                    Navigator.of(context).pop();
                    actions[i].onSelected();
                  },
                  builder: (context, focused) => AnimatedContainer(
                    duration: VMotion.focus,
                    height: 68,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    decoration: BoxDecoration(
                      color: focused ? Colors.white : const Color(0x0DFFFFFF),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        Icon(actions[i].icon, size: 26, color: focused ? const Color(0xFF0B0C10) : Colors.white),
                        const SizedBox(width: 16),
                        Text(
                          actions[i].label,
                          style: TextStyle(fontSize: 22, color: focused ? const Color(0xFF0B0C10) : Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
