import 'package:flutter/material.dart';

import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../focus/focus_auto_scroll.dart';
import '../focus/input_mode.dart';
import '../focus/focusable.dart';
import '../glass/glass.dart';

class MenuAction {
  const MenuAction(this.label, this.icon, this.onSelected, {this.detail}) : submenuTitle = null, submenu = null;

  /// 打开二级菜单：二级菜单出现在这一级旁边，这一级保持显示；二级菜单里选完回到这一级（显示更新后的值）
  const MenuAction.submenu(
    this.label,
    this.icon, {
    required String title,
    required List<MenuAction> Function() items,
    this.detail,
  }) : submenuTitle = title,
       submenu = items,
       onSelected = _noop;

  final String label;

  /// 第二行的灰色说明（如当前生效的值），菜单窄时也完整显示，不和标题挤在一行被截掉
  final String? detail;
  final IconData icon;
  final VoidCallback onSelected;
  final String? submenuTitle;
  final List<MenuAction> Function()? submenu;

  static void _noop() {}
}

/// 上下文菜单：从右侧滑入的磨砂玻璃面板（docs/07-input-control.md §3.4）。
/// ↑↓ 选择，OK 执行，返回 / ← 关闭。
///
/// [actionsBuilder]：菜单项随状态变化时（二级菜单里改了值，回来要显示新值）传它代替 [actions]。
Future<void> showContextMenu(
  BuildContext context, {
  required String title,
  List<MenuAction> actions = const [],
  List<MenuAction> Function()? actionsBuilder,
}) => _showMenu(context, title: title, actions: actionsBuilder ?? () => actions, depth: 0);

Future<void> _showMenu(
  BuildContext context, {
  required String title,
  required List<MenuAction> Function() actions,
  required int depth,
  Rect? item,
}) {
  if (PlatformProfile.isDesktop) {
    return _showPopupMenu(context, title: title, actions: actions, depth: depth, item: item);
  }
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭菜单',
    // 二级菜单不再加一层暗色
    barrierColor: depth == 0 ? const Color(0x6607080B) : const Color(0x00000000),
    transitionDuration: VMotion.scroll,
    pageBuilder: (context, _, _) => _ContextMenuPanel(title: title, actions: actions, depth: depth),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return SlideTransition(
        position: Tween(begin: const Offset(0.3, 0), end: Offset.zero).animate(curved),
        child: FadeTransition(opacity: curved, child: child),
      );
    },
  );
}

/// 选中一项：普通项关闭这一级再执行；二级菜单项打开下一级，关闭后刷新这一级
Future<void> _select(BuildContext context, MenuAction action, int depth, VoidCallback refresh, {Rect? item}) async {
  final items = action.submenu;
  if (items == null) {
    Navigator.of(context).pop();
    action.onSelected();
    return;
  }
  await _showMenu(context, title: action.submenuTitle ?? action.label, actions: items, depth: depth + 1, item: item);
  refresh();
}

/// 一个菜单项在屏幕上的位置（Windows 二级菜单贴着它弹出）
Rect? _rectOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

class _ContextMenuPanel extends StatefulWidget {
  const _ContextMenuPanel({required this.title, required this.actions, required this.depth});

  final String title;
  final List<MenuAction> Function() actions;
  final int depth;

  /// 面板宽度与间距：二级菜单放在上一级的左边，上一级保持可见
  static const width = 560.0;
  static const gap = 24.0;

  @override
  State<_ContextMenuPanel> createState() => _ContextMenuPanelState();
}

class _ContextMenuPanelState extends State<_ContextMenuPanel> {
  @override
  Widget build(BuildContext context) {
    final actions = widget.actions();
    final title = widget.title;
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: EdgeInsets.fromLTRB(32, 32, 32 + widget.depth * (_ContextMenuPanel.width + _ContextMenuPanel.gap), 32),
        child: Glass(
          width: _ContextMenuPanel.width,
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
              // 项目多（如剧集列表）时可以滚动，焦点移到哪就滚到哪
              Flexible(
                child: FocusAutoScroll(
                  alignment: 0.5,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < actions.length; i++) ...[
                          VFocusable(
                            autofocus: i == 0,
                            radius: VRadius.md,
                            scale: 1.02,
                            showRing: false,
                            onActivate: () =>
                                _select(context, actions[i], widget.depth, () => mounted ? setState(() {}) : null),
                            builder: (context, focused) => AnimatedContainer(
                              duration: VMotion.focus,
                              height: actions[i].detail == null ? 68 : 88,
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                              decoration: BoxDecoration(
                                color: focused ? Colors.white : const Color(0x0DFFFFFF),
                                borderRadius: BorderRadius.circular(VRadius.md),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    actions[i].icon,
                                    size: 26,
                                    color: focused ? const Color(0xFF0B0C10) : Colors.white,
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: _ItemText(
                                      label: actions[i].label,
                                      detail: actions[i].detail,
                                      size: 22,
                                      color: focused ? const Color(0xFF0B0C10) : Colors.white,
                                      detailColor: focused ? const Color(0x990B0C10) : const Color(0x99FFFFFF),
                                    ),
                                  ),
                                  if (actions[i].submenu != null)
                                    Icon(
                                      Icons.chevron_right_rounded,
                                      size: 28,
                                      color: focused ? const Color(0xFF0B0C10) : const Color(0x99FFFFFF),
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Windows：在鼠标位置（键盘操作时在当前焦点元素旁）弹出紧凑菜单
Future<void> _showPopupMenu(
  BuildContext context, {
  required String title,
  required List<MenuAction> Function() actions,
  required int depth,
  Rect? item,
}) {
  final overlay = Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
  Offset? anchor;
  double? altX;
  // 二级菜单：放在上一级那一项的右边，放不下时放到上一级的左边（不盖住上一级）
  if (item != null) {
    anchor = overlay.globalToLocal(item.topRight + const Offset(6, -10));
    altX = overlay.globalToLocal(item.topLeft).dx - 16;
  } else if (InputMode.pointer && InputMode.lastPointer != null) {
    anchor = overlay.globalToLocal(InputMode.lastPointer!);
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
      delegate: _PopupLayout(anchor ?? Offset(overlay.size.width / 2, overlay.size.height / 3), altX: altX),
      child: _PopupMenu(title: title, actions: actions, depth: depth),
    ),
    transitionBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
  );
}

/// 菜单左上角放在锚点，超出窗口时往回收
class _PopupLayout extends SingleChildLayoutDelegate {
  _PopupLayout(this.anchor, {this.altX});

  final Offset anchor;

  /// 右边放不下时菜单右边缘放在这里（二级菜单翻到上一级左边）
  final double? altX;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen().deflate(const EdgeInsets.all(16));

  @override
  Offset getPositionForChild(Size size, Size child) {
    const margin = 16.0;
    var x = anchor.dx;
    var y = anchor.dy;
    if (x + child.width > size.width - margin) x = (altX ?? anchor.dx) - child.width;
    if (y + child.height > size.height - margin) y = size.height - margin - child.height;
    return Offset(x.clamp(margin, size.width - child.width - margin), y.clamp(margin, size.height - margin));
  }

  @override
  bool shouldRelayout(_PopupLayout old) => old.anchor != anchor || old.altX != altX;
}

class _PopupMenu extends StatefulWidget {
  const _PopupMenu({required this.title, required this.actions, required this.depth});

  final String title;
  final List<MenuAction> Function() actions;
  final int depth;

  @override
  State<_PopupMenu> createState() => _PopupMenuState();
}

class _PopupMenuState extends State<_PopupMenu> {
  final _keys = <int, GlobalKey>{};
  GlobalKey _itemKey(int i) => _keys.putIfAbsent(i, GlobalKey.new);
  Map<int, BuildContext?> get _itemContexts => {for (final e in _keys.entries) e.key: e.value.currentContext};

  @override
  Widget build(BuildContext context) {
    final actions = widget.actions();
    final title = widget.title;
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
            Flexible(
              child: FocusAutoScroll(
                alignment: 0.5,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < actions.length; i++)
                        VFocusable(
                          autofocus: i == 0 && !InputMode.pointer,
                          radius: VRadius.sm,
                          scale: 1,
                          showRing: false,
                          onActivate: () => _select(
                            context,
                            actions[i],
                            widget.depth,
                            () => mounted ? setState(() {}) : null,
                            item: _rectOf(_itemContexts[i] ?? context),
                          ),
                          builder: (context, focused) => AnimatedContainer(
                            key: _itemKey(i),
                            duration: VMotion.focus,
                            height: actions[i].detail == null ? 50 : 64,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              color: focused ? const Color(0x24FFFFFF) : const Color(0x00FFFFFF),
                              borderRadius: BorderRadius.circular(VRadius.sm),
                            ),
                            child: Row(
                              children: [
                                Icon(actions[i].icon, size: 22, color: Colors.white),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: _ItemText(
                                    label: actions[i].label,
                                    detail: actions[i].detail,
                                    size: 20,
                                    color: Colors.white,
                                    detailColor: const Color(0x99FFFFFF),
                                  ),
                                ),
                                if (actions[i].submenu != null)
                                  const Icon(Icons.chevron_right_rounded, size: 22, color: Color(0x99FFFFFF)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 菜单项文字：标题一行，有说明时下面一行小一号的灰字
class _ItemText extends StatelessWidget {
  const _ItemText({
    required this.label,
    required this.detail,
    required this.size,
    required this.color,
    required this.detailColor,
  });

  final String label;
  final String? detail;
  final double size;
  final Color color;
  final Color detailColor;

  @override
  Widget build(BuildContext context) {
    final title = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: size, color: color),
    );
    if (detail == null) return title;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        title,
        const SizedBox(height: 2),
        Text(
          detail!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: size * 0.75, color: detailColor),
        ),
      ],
    );
  }
}
