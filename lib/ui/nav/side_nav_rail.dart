import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/desktop_prefs.dart';
import '../../data/config/config_store.dart';
import '../../features/library/library_page.dart' show ServerTypeLogo;
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
  downloads('/downloads', '下载', Icons.download_rounded),
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
/// 两种样式（设置 → 通用与关于 → 导航栏）：默认是撑满高度的一长条、设置在最下面；
/// 紧凑是高度随项目多少、整体上下居中。搜索、服务器在线状态和时间在右上角（[TopRightBar]）。
/// - Windows：鼠标移到上面展开，移开立即收起（键盘操作时随焦点展开）。
/// - Android TV：焦点进入时展开，离开时收起。
class SideNavRail extends StatefulWidget {
  const SideNavRail({
    super.key,
    required this.active,
    required this.nodes,
    required this.scope,
    required this.onSelect,
    this.location = '',
    this.onOpenServer,
    this.onPointerLeave,
  });

  /// 当前页面地址（固定的服务器正在打开时高亮）
  final String location;

  /// 点了固定在导航栏里的服务器
  final ValueChanged<String>? onOpenServer;

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
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: DesktopPrefs.instance.navCompact,
    builder: (context, compact, _) => _build(context, compact),
  );

  /// 紧凑：高度随项目多少、上下居中；默认：撑满整个高度
  static Widget _maybeCenter(bool compact, Widget child) =>
      compact ? Align(alignment: Alignment.centerLeft, child: child) : child;

  Widget _build(BuildContext context, bool compact) {
    final width = _expanded ? VSpace.navRailExpandedWidth : VSpace.navRailWidth;
    // 搜索在右上角（和电视一样），不占导航栏
    final main = NavItem.values.where((i) => i != NavItem.settings && i != NavItem.search);
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
          child: _maybeCenter(
            compact,
            MouseRegion(
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
                    mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Logo(expanded: _expanded),
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
                      // 资源库里右键「添加到侧边栏」的服务器
                      // 固定的服务器多了放不下时可以滚动，不把「设置」挤出去。
                      // 撑满高度时它要吃掉剩下的全部空间（不能再和 Spacer 平分），「设置」才会贴到最下面
                      Flexible(
                        fit: compact ? FlexFit.loose : FlexFit.tight,
                        child: SingleChildScrollView(
                          clipBehavior: Clip.none,
                          child: _PinnedServers(
                            location: widget.location,
                            expanded: _expanded,
                            onOpen: widget.onOpenServer,
                          ),
                        ),
                      ),
                      if (compact)
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
                    // 跟着「桌面图标」设置换（日间 / 默认 / 跟随系统），和任务栏、托盘一致
                    child: ValueListenableBuilder<bool>(
                      valueListenable: DesktopPrefs.instance.lightIcon,
                      builder: (context, light, _) => Image.asset(
                        light ? 'assets/images/app_icon_light.png' : 'assets/images/app_icon.png',
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

/// 固定在导航栏里的服务器：分隔线下面一台一行，图标是服务器类型的官方图标
class _PinnedServers extends ConsumerStatefulWidget {
  const _PinnedServers({required this.location, required this.expanded, this.onOpen});

  final String location;
  final bool expanded;
  final ValueChanged<String>? onOpen;

  @override
  ConsumerState<_PinnedServers> createState() => _PinnedServersState();
}

class _PinnedServersState extends ConsumerState<_PinnedServers> {
  final _nodes = <String, FocusNode>{};

  @override
  void dispose() {
    for (final n in _nodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(configProvider.select((c) => c.servers));
    return ValueListenableBuilder<List<String>>(
      valueListenable: DesktopPrefs.instance.pinnedServers,
      builder: (context, pinned, _) {
        final list = [for (final id in pinned) ?servers.where((s) => s.id == id).firstOrNull];
        if (list.isEmpty) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 14),
              width: 32,
              height: 1,
              color: const Color(0x24FFFFFF),
            ),
            for (final s in list) ...[
              _ServerRailItem(
                label: s.displayName,
                icon: ServerTypeLogo(s.type),
                node: _nodes.putIfAbsent(s.id, () => FocusNode(debugLabel: 'nav:server:${s.id}')),
                active: widget.location.startsWith('/library/server/${s.id}'),
                expanded: widget.expanded,
                onSelect: () => widget.onOpen?.call(s.id),
              ),
              const SizedBox(height: 14),
            ],
          ],
        );
      },
    );
  }
}

class _ServerRailItem extends StatelessWidget {
  const _ServerRailItem({
    required this.label,
    required this.icon,
    required this.node,
    required this.active,
    required this.expanded,
    required this.onSelect,
  });

  final String label;
  final Widget icon;
  final FocusNode node;
  final bool active;
  final bool expanded;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: expanded ? '' : label,
      excludeFromSemantics: true,
      child: VFocusable(
        semanticLabel: label,
        selected: active,
        focusNode: node,
        radius: VRadius.sm,
        scale: 1.04,
        alignment: Alignment.centerLeft,
        showRing: false,
        onActivate: onSelect,
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
                      child: Center(child: SizedBox.square(dimension: 30, child: icon)),
                    ),
                    if (expanded) ...[
                      const SizedBox(width: 4),
                      SizedBox(
                        width: VSpace.navRailExpandedWidth - 32 - 56 - 4 - 12,
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 22,
                            color: fg,
                            fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                          ),
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
