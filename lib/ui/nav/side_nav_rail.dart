import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/desktop_prefs.dart';
import '../../app/theme.dart';
import '../../data/config/config_store.dart';
import '../focus/focusable.dart';
import '../focus/input_mode.dart';
import '../glass/glass.dart';
import '../widgets/status_bar.dart';

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
/// 高度随项目多少，整体上下居中；顶部 Logo 下面是时钟，「资源库」图标上的小点是服务器在线状态。
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
          // 高度随项目多少，上下居中（不再撑满整个高度、设置孤零零在最下面）
          child: Align(
            alignment: Alignment.centerLeft,
            child: MouseRegion(
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => _onPointerExit(),
              child: AnimatedContainer(
                duration: VMotion.scroll,
                curve: Curves.easeOutCubic,
                width: width,
                child: Glass(
                  radius: VRadius.panel,
                  fill: _expanded ? const Color(0x2914161E) : VColors.glassFill,
                  padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Logo(expanded: _expanded),
                      const SizedBox(height: 10),
                      const _NavClock(),
                      const SizedBox(height: 24),
                      for (final item in main) ...[
                        _RailItem(
                          item: item,
                          node: widget.nodes[item.path]!,
                          active: item == widget.active,
                          expanded: _expanded,
                          onSelect: widget.onSelect,
                          serverStatus: item == NavItem.library,
                        ),
                        const SizedBox(height: 14),
                      ],
                      // 和上面的页面分开一点
                      Container(
                        margin: const EdgeInsets.fromLTRB(12, 4, 12, 18),
                        width: 32,
                        height: 1,
                        color: const Color(0x24FFFFFF),
                      ),
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
        ),
      ],
    );
  }
}

/// 导航栏顶部的时钟（原来在首页右上角）
class _NavClock extends StatelessWidget {
  const _NavClock();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 56,
    child: Center(
      child: ClockText(
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: Color(0xCCFFFFFF),
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    ),
  );
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.item,
    required this.node,
    required this.active,
    required this.expanded,
    required this.onSelect,
    this.serverStatus = false,
  });

  final NavItem item;
  final FocusNode node;
  final bool active;
  final bool expanded;
  final ValueChanged<NavItem> onSelect;

  /// 图标右上角显示服务器在线状态的小点（资源库）
  final bool serverStatus;

  @override
  Widget build(BuildContext context) {
    if (serverStatus) {
      return Consumer(
        builder: (context, ref, _) {
          final st = serverStatusOf(ref.watch(configProvider.select((c) => c.servers)));
          return Tooltip(
            message: st.total == 0 ? '' : '${st.online} / ${st.total} 台服务器在线',
            waitDuration: const Duration(milliseconds: 400),
            child: _build(context, st.total == 0 ? null : st),
          );
        },
      );
    }
    return _build(context, null);
  }

  Widget _build(BuildContext context, ({int online, int total, Color color})? st) {
    return VFocusable(
      semanticLabel: st == null ? item.label : '${item.label}，${st.online} / ${st.total} 台服务器在线',
      selected: active,
      focusNode: node,
      radius: VRadius.sm,
      scale: 1.04,
      alignment: Alignment.centerLeft,
      showRing: false,
      onActivate: () => onSelect(item),
      builder: (context, focused) {
        final Color bg = focused ? Colors.white : (active ? const Color(0x29FFFFFF) : const Color(0x00FFFFFF));
        final Color fg = focused ? const Color(0xFF0B0C10) : (active ? Colors.white : const Color(0x9EFFFFFF));
        return AnimatedContainer(
          duration: VMotion.duration(context, VMotion.focus),
          height: 56,
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(VRadius.sm)),
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              maxWidth: VSpace.navRailExpandedWidth,
              child: Row(
                children: [
                  SizedBox(
                    width: 56,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        Icon(item.icon, size: 28, color: fg),
                        // 服务器在线状态：全部在线绿、部分橙、都不在线红
                        if (st != null)
                          Positioned(
                            right: 9,
                            top: 10,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: st.color,
                                border: Border.all(
                                  color: bg == Colors.white ? Colors.white : const Color(0xFF14161E),
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (expanded) ...[
                    const SizedBox(width: 4),
                    Text(
                      item.label,
                      style: TextStyle(fontSize: 22, color: fg, fontWeight: active ? FontWeight.w700 : FontWeight.w400),
                    ),
                    if (st != null) ...[
                      const SizedBox(width: 10),
                      Text(
                        '${st.online}/${st.total} 在线',
                        style: TextStyle(fontSize: 16, color: fg.withValues(alpha: 0.6)),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.expanded});

  /// 展开时图标旁边淡入「Viora」字样
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          maxWidth: VSpace.navRailExpandedWidth,
          child: Row(
            children: [
              SizedBox(
                width: 56,
                child: Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(VRadius.sm),
                    child: ValueListenableBuilder<bool>(
                      valueListenable: DesktopPrefs.instance.lightIcon,
                      builder: (context, light, _) => Image.asset(
                        DesktopPrefs.logoAsset(light),
                        width: 44,
                        height: 44,
                        filterQuality: FilterQuality.medium,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              AnimatedOpacity(
                opacity: expanded ? 1 : 0,
                duration: VMotion.focus,
                child: AnimatedSlide(
                  offset: expanded ? Offset.zero : const Offset(-0.15, 0),
                  duration: VMotion.focus,
                  curve: Curves.easeOutCubic,
                  child: const Text(
                    'Viora',
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 0.5, height: 1),
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
