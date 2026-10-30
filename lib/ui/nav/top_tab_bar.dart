import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../focus/focusable.dart';
import 'side_nav_rail.dart' show NavItem;

/// 电视顶部标签栏（Windows 仍用左侧 [SideNavRail]）。
///
/// 一排文字标签：在页面第一行按 ↑ 进入，←→ 切换，OK 打开，↓ 回到内容。
/// 不展开、不压暗、没有毛玻璃：切换只是高亮从一个标签移到另一个，弱 GPU 的电视盒子也不掉帧。
/// 页面往下翻时滑出屏幕（[visible]），回到顶部或焦点进入时再出现。
class TopTabBar extends StatelessWidget {
  const TopTabBar({
    super.key,
    required this.active,
    required this.nodes,
    required this.onSelect,
    required this.visible,
  });

  final NavItem active;
  final Map<String, FocusNode> nodes;
  final ValueChanged<NavItem> onSelect;
  final bool visible;

  /// 标签顺序：首页在最前（打开应用时焦点在首页，按 ↑ 正好落在它上面）
  static const items = [
    NavItem.home,
    NavItem.search,
    NavItem.library,
    NavItem.favorites,
    NavItem.history,
    NavItem.settings,
  ];

  @override
  Widget build(BuildContext context) {
    final duration = VMotion.duration(context, VMotion.focus);
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        offset: visible ? Offset.zero : const Offset(0, -1),
        duration: duration,
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: duration,
          child: Container(
            height: VSpace.topBarBottom,
            padding: const EdgeInsets.only(left: VSpace.safeH, right: VSpace.safeH, top: 36),
            alignment: Alignment.topLeft,
            // 只是一层渐变，让标签在海报 / 大图上看得清
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xCC07080B), Color(0x0007080B)],
              ),
            ),
            child: FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(VRadius.sm),
                    child: Image.asset(
                      'assets/images/app_icon.png',
                      width: 44,
                      height: 44,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                  const SizedBox(width: 28),
                  for (final (i, item) in items.indexed) ...[
                    if (i > 0) const SizedBox(width: 8),
                    FocusTraversalOrder(
                      order: NumericFocusOrder(i.toDouble()),
                      child: _Tab(item: item, node: nodes[item.path]!, active: item == active, onSelect: onSelect),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.item, required this.node, required this.active, required this.onSelect});

  final NavItem item;
  final FocusNode node;
  final bool active;
  final ValueChanged<NavItem> onSelect;

  @override
  Widget build(BuildContext context) {
    return VFocusable(
      semanticLabel: item.label,
      selected: active,
      focusNode: node,
      radius: VRadius.pill,
      scale: 1.06,
      showRing: false,
      onActivate: () => onSelect(item),
      builder: (context, focused) {
        final Color fg = focused
            ? VColors.background
            : active
            ? Colors.white
            : const Color(0x9EFFFFFF);
        return Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 26),
          decoration: BoxDecoration(
            color: focused ? Colors.white : const Color(0x00FFFFFF),
            borderRadius: BorderRadius.circular(VRadius.pill),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                item.label,
                style: TextStyle(
                  fontSize: 24,
                  height: 1.1,
                  color: fg,
                  fontWeight: active || focused ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
              // 当前页面：标签下一条短线（焦点不在这里时也能看出在哪个页面）
              Container(
                margin: const EdgeInsets.only(top: 4),
                width: 22,
                height: 3,
                decoration: BoxDecoration(
                  color: active && !focused ? Colors.white : const Color(0x00FFFFFF),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
