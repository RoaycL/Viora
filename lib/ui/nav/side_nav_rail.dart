import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../focus/focusable.dart';
import '../focus/input_mode.dart';
import '../glass/glass.dart';

enum NavItem {
  search('/search', '搜索', Icons.search_rounded),
  home('/', '首页', Icons.home_rounded),
  library('/library', '资源库', Icons.dns_rounded),
  favorites('/favorites', '收藏', Icons.favorite_border_rounded),
  history('/history', '观看记录', Icons.history_rounded),
  settings('/settings', '设置', Icons.settings_outlined);

  const NavItem(this.path, this.label, this.icon);

  final String path;
  final String label;
  final IconData icon;

  static NavItem forLocation(String location) {
    for (final item in values) {
      if (item != home && location.startsWith(item.path)) return item;
    }
    return home;
  }
}

/// 左侧磨砂玻璃导航栏：收起时 88 宽只显示图标（始终显示），展开到 280 并显示文字。
/// - Windows：鼠标移到上面展开，移开立即收起（键盘操作时随焦点展开）。
/// - Android TV：焦点进入时展开，离开时收起。
class SideNavRail extends StatefulWidget {
  const SideNavRail({
    super.key,
    required this.active,
    required this.nodes,
    required this.scope,
    required this.onSelect,
    this.onPointerLeave,
  });

  /// 鼠标离开导航栏（Windows）：把焦点还给内容区
  final VoidCallback? onPointerLeave;

  final NavItem active;
  final Map<String, FocusNode> nodes;
  final FocusScopeNode scope;
  final ValueChanged<NavItem> onSelect;

  @override
  State<SideNavRail> createState() => _SideNavRailState();
}

class _SideNavRailState extends State<SideNavRail> {
  /// 遥控器 / 键盘焦点在导航栏里
  bool _focused = false;

  /// 鼠标在导航栏上（Windows）
  bool _hover = false;

  /// 展开：电视看焦点；Windows 鼠标悬停时展开、移开立即收起（键盘操作时看焦点）
  bool get _expanded => _hover || (_focused && !InputMode.pointer);

  @override
  void initState() {
    super.initState();
    widget.scope.addListener(_onScopeFocus);
  }

  @override
  void dispose() {
    widget.scope.removeListener(_onScopeFocus);
    super.dispose();
  }

  void _onScopeFocus() {
    if (_focused != widget.scope.hasFocus) setState(() => _focused = widget.scope.hasFocus);
  }

  void _onPointerExit() {
    setState(() => _hover = false);
    // 鼠标悬停会让导航项获得焦点；移开后把焦点还给内容区，避免导航项一直保持高亮
    if (widget.scope.hasFocus) widget.onPointerLeave?.call();
  }

  @override
  Widget build(BuildContext context) {
    final width = _expanded ? VSpace.navRailExpandedWidth : VSpace.navRailWidth;
    final main = NavItem.values.where((i) => i != NavItem.settings);
    return Stack(
      children: [
        // 展开时压暗内容（遮盖而不推挤）
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _expanded ? 1 : 0,
              duration: VMotion.scroll,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [Color(0xD907080B), Color(0x0007080B)], stops: [0.15, 0.5]),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 24,
          top: VSpace.safeV,
          bottom: VSpace.safeV,
          child: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => _onPointerExit(),
            child: AnimatedContainer(
              duration: VMotion.scroll,
              curve: Curves.easeOutCubic,
              width: width,
              child: Glass(
                radius: 28,
                fill: _expanded ? const Color(0x2914161E) : VColors.glassFill,
                padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Logo(),
                    const SizedBox(height: 32),
                    for (final item in main) ...[
                      _RailItem(
                        item: item,
                        node: widget.nodes[item.path]!,
                        active: item == widget.active,
                        expanded: _expanded,
                        onSelect: widget.onSelect,
                      ),
                      const SizedBox(height: 14),
                    ],
                    const Spacer(),
                    _RailItem(
                      item: NavItem.settings,
                      node: widget.nodes[NavItem.settings.path]!,
                      active: widget.active == NavItem.settings,
                      expanded: _expanded,
                      onSelect: widget.onSelect,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.item,
    required this.node,
    required this.active,
    required this.expanded,
    required this.onSelect,
  });

  final NavItem item;
  final FocusNode node;
  final bool active;
  final bool expanded;
  final ValueChanged<NavItem> onSelect;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      label: item.label,
      child: VFocusable(
        focusNode: node,
        radius: 18,
        scale: 1.04,
        alignment: Alignment.centerLeft,
        showRing: false,
        onActivate: () => onSelect(item),
        builder: (context, focused) {
          final Color bg = focused ? Colors.white : (active ? const Color(0x29FFFFFF) : const Color(0x00FFFFFF));
          final Color fg = focused ? const Color(0xFF0B0C10) : (active ? Colors.white : const Color(0x9EFFFFFF));
          return AnimatedContainer(
            duration: VMotion.focus,
            height: 56,
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(18)),
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                maxWidth: VSpace.navRailExpandedWidth,
                child: Row(
                  children: [
                    SizedBox(width: 56, child: Icon(item.icon, size: 28, color: fg)),
                    if (expanded) ...[
                      const SizedBox(width: 4),
                      Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 22,
                          color: fg,
                          fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      child: Center(
        child: ShaderMask(
          shaderCallback: (rect) => const LinearGradient(colors: [Colors.white, VColors.accent]).createShader(rect),
          child: const Text(
            'V',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
