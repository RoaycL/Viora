import 'package:flutter/material.dart';

import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../focus/input_mode.dart';
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
  if (PlatformProfile.isDesktop) return _showPopupMenu(context, title: title, actions: actions);
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
          radius: VRadius.panel,
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
                  radius: VRadius.md,
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
                      borderRadius: BorderRadius.circular(VRadius.md),
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

/// Windows：在鼠标位置（键盘操作时在当前焦点元素旁）弹出紧凑菜单
Future<void> _showPopupMenu(BuildContext context, {required String title, required List<MenuAction> actions}) {
  final overlay = Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
  Offset? anchor;
  final pointer = InputMode.lastPointer;
  if (InputMode.pointer && pointer != null) {
    anchor = overlay.globalToLocal(pointer);
  } else {
    final focused = FocusManager.instance.primaryFocus?.context?.findRenderObject();
    if (focused is RenderBox && focused.attached) {
      anchor = overlay.globalToLocal(focused.localToGlobal(Offset(focused.size.width, 0)));
    }
  }
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭菜单',
    barrierColor: const Color(0x00000000),
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (context, _, _) => CustomSingleChildLayout(
      delegate: _PopupLayout(anchor ?? Offset(overlay.size.width / 2, overlay.size.height / 3)),
      child: _PopupMenu(title: title, actions: actions),
    ),
    transitionBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
  );
}

/// 菜单左上角放在锚点，超出窗口时往回收
class _PopupLayout extends SingleChildLayoutDelegate {
  _PopupLayout(this.anchor);

  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size child) {
    const margin = 16.0;
    var x = anchor.dx;
    var y = anchor.dy;
    if (x + child.width > size.width - margin) x = anchor.dx - child.width;
    if (y + child.height > size.height - margin) y = size.height - margin - child.height;
    return Offset(x.clamp(margin, size.width - child.width - margin), y.clamp(margin, size.height - margin));
  }

  @override
  bool shouldRelayout(_PopupLayout old) => old.anchor != anchor;
}

class _PopupMenu extends StatelessWidget {
  const _PopupMenu({required this.title, required this.actions});

  final String title;
  final List<MenuAction> actions;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Glass(
        width: 380,
        radius: VRadius.card,
        blur: 30,
        fill: const Color(0xE614161E),
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VText.small.copyWith(color: VColors.textTertiary),
                ),
              ),
            for (var i = 0; i < actions.length; i++)
              VFocusable(
                autofocus: i == 0 && !InputMode.pointer,
                radius: VRadius.sm,
                scale: 1,
                showRing: false,
                onActivate: () {
                  Navigator.of(context).pop();
                  actions[i].onSelected();
                },
                builder: (context, focused) => AnimatedContainer(
                  duration: VMotion.focus,
                  height: 50,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: focused ? const Color(0x24FFFFFF) : const Color(0x00FFFFFF),
                    borderRadius: BorderRadius.circular(VRadius.sm),
                  ),
                  child: Row(
                    children: [
                      Icon(actions[i].icon, size: 22, color: Colors.white),
                      const SizedBox(width: 14),
                      Text(actions[i].label, style: const TextStyle(fontSize: 20, color: Colors.white)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
