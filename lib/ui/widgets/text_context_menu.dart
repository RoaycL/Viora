import 'package:flutter/material.dart';

import '../../app/platform_profile.dart';
import '../../app/theme.dart';

/// 输入框右键 / 长按菜单（剪切、复制、粘贴、全选）：和应用里其他弹出菜单一样的深色磨砂样式，
/// 代替 Flutter 默认的那条细长黑条（字小、没有边框，在深色输入框上几乎看不出来）。
Widget textContextMenu(BuildContext context, EditableTextState state) {
  final items = state.contextMenuButtonItems;
  if (items.isEmpty) return const SizedBox.shrink();
  final anchors = state.contextMenuAnchors;
  final menu = _TextMenu(items: items, vertical: PlatformProfile.isDesktop);
  if (PlatformProfile.isDesktop) {
    return CustomSingleChildLayout(
      delegate: DesktopTextSelectionToolbarLayoutDelegate(anchor: anchors.primaryAnchor),
      child: menu,
    );
  }
  return CustomSingleChildLayout(
    delegate: TextSelectionToolbarLayoutDelegate(
      anchorAbove: anchors.primaryAnchor - const Offset(0, 12),
      anchorBelow: (anchors.secondaryAnchor ?? anchors.primaryAnchor) + const Offset(0, 12),
    ),
    child: menu,
  );
}

class _TextMenu extends StatelessWidget {
  const _TextMenu({required this.items, required this.vertical});

  final List<ContextMenuButtonItem> items;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final buttons = [
      for (final item in items)
        _TextMenuButton(
          label: item.label ?? AdaptiveTextSelectionToolbar.getButtonLabel(context, item),
          icon: _icon(item.type),
          onPressed: item.onPressed,
          vertical: vertical,
        ),
    ];
    return Material(
      type: MaterialType.transparency,
      child: Container(
        constraints: vertical ? const BoxConstraints(minWidth: 168) : null,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: const Color(0xF21C1E26),
          borderRadius: BorderRadius.circular(VRadius.card),
          border: Border.all(color: const Color(0x26FFFFFF)),
          boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8))],
        ),
        child: vertical
            ? IntrinsicWidth(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: buttons,
                ),
              )
            : Row(mainAxisSize: MainAxisSize.min, children: buttons),
      ),
    );
  }

  static IconData? _icon(ContextMenuButtonType type) => switch (type) {
    ContextMenuButtonType.cut => Icons.content_cut_rounded,
    ContextMenuButtonType.copy => Icons.content_copy_rounded,
    ContextMenuButtonType.paste => Icons.content_paste_rounded,
    ContextMenuButtonType.selectAll => Icons.select_all_rounded,
    _ => null,
  };
}

class _TextMenuButton extends StatefulWidget {
  const _TextMenuButton({required this.label, required this.icon, required this.onPressed, required this.vertical});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool vertical;

  @override
  State<_TextMenuButton> createState() => _TextMenuButtonState();
}

class _TextMenuButtonState extends State<_TextMenuButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: VMotion.focus,
          height: widget.vertical ? 40 : 48,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: _hover ? const Color(0x1FFFFFFF) : const Color(0x00FFFFFF),
            borderRadius: BorderRadius.circular(VRadius.sm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 18, color: const Color(0xD9FFFFFF)),
                const SizedBox(width: 10),
              ],
              Text(widget.label, style: const TextStyle(fontSize: 17, color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}
