import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../ui/focus/shell_focus.dart';
import '../ui/nav/side_nav_rail.dart';
import '../ui/nav/top_tab_bar.dart';
import 'platform_profile.dart';
import 'theme.dart';

/// 应用壳：导航 + 内容区，两者是独立的焦点区域。
/// - Windows：左侧导航栏，内容最左侧按 ← 进入，按 → 回到内容。
/// - 电视：顶部标签栏（[TopTabBar]），内容第一行按 ↑ 进入，按 ↓ 回到内容；页面往下翻时标签栏滑出屏幕。
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _railScope = FocusScopeNode(debugLabel: 'rail');
  final _contentScope = FocusScopeNode(debugLabel: 'content');
  final _railNodes = <String, FocusNode>{
    for (final item in NavItem.values) item.path: FocusNode(debugLabel: 'nav:${item.path}'),
  };

  /// 电视用顶部标签栏
  final bool _topBar = PlatformProfile.isTv;

  /// 内容区滚动在顶部附近（电视标签栏据此显示 / 隐藏）
  bool _atTop = true;
  bool _barFocused = false;

  @override
  void initState() {
    super.initState();
    ShellController.instance._attach(this);
    _railScope.addListener(_onBarFocus);
  }

  void _onBarFocus() {
    if (_topBar && _barFocused != _railScope.hasFocus) setState(() => _barFocused = _railScope.hasFocus);
  }

  @override
  void didUpdateWidget(AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换页面后新页面从顶部开始
    if (oldWidget.location != widget.location) _atTop = true;
  }

  bool _onScroll(ScrollNotification n) {
    if (!_topBar || n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    final atTop = n.metrics.pixels <= 40;
    if (atTop != _atTop) setState(() => _atTop = atTop);
    return false;
  }

  @override
  void dispose() {
    ShellController.instance._detach(this);
    _railScope.removeListener(_onBarFocus);
    _railScope.dispose();
    _contentScope.dispose();
    for (final node in _railNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  NavItem get _active => NavItem.forLocation(widget.location);

  void focusRail() => _railNodes[_active.path]!.requestFocus();

  void focusContent() {
    final last = _contentScope.focusedChild;
    if (last != null && last.context != null) {
      last.requestFocus();
    } else {
      _contentScope.requestFocus();
      _contentScope.nextFocus();
    }
  }

  void _select(NavItem item) {
    if (item != _active) context.go(item.path);
    // 选中后进入内容区；新页面的 autofocus 会接管焦点。
    WidgetsBinding.instance.addPostFrameCallback((_) => focusContent());
  }

  @override
  Widget build(BuildContext context) {
    // 电视：内容第一行按 ↑ 进入标签栏、标签栏按 ↓ 回到内容；Windows：← 进入侧边栏、→ 回到内容
    final toBar = _topBar ? TraversalDirection.up : TraversalDirection.left;
    final toContent = _topBar ? TraversalDirection.down : TraversalDirection.right;
    final nav = _topBar
        ? TopTabBar(active: _active, nodes: _railNodes, visible: _atTop || _barFocused, onSelect: _select)
        : SideNavRail(
            active: _active,
            nodes: _railNodes,
            scope: _railScope,
            onPointerLeave: focusContent,
            onSelect: _select,
          );
    return ShellFocus(
      focusRail: focusRail,
      focusContent: focusContent,
      topBar: _topBar,
      child: ColoredBox(
        color: VColors.background,
        child: Stack(
          children: [
            Positioned.fill(
              child: FocusScope(
                node: _contentScope,
                child: Actions(
                  actions: <Type, Action<Intent>>{
                    DirectionalFocusIntent: EdgeAwareDirectionalAction((direction) {
                      if (direction == toBar) focusRail();
                      return true;
                    }),
                  },
                  child: NotificationListener<ScrollNotification>(onNotification: _onScroll, child: widget.child),
                ),
              ),
            ),
            FocusScope(
              node: _railScope,
              child: Actions(
                actions: <Type, Action<Intent>>{
                  DirectionalFocusIntent: EdgeAwareDirectionalAction((direction) {
                    if (direction == toContent) focusContent();
                    return true;
                  }),
                },
                child: nav,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 供应用级返回键逻辑查询导航栏状态。
class ShellController {
  ShellController._();

  static final instance = ShellController._();

  _AppShellState? _state;

  void _attach(_AppShellState state) => _state = state;

  void _detach(_AppShellState state) {
    if (identical(_state, state)) _state = null;
  }

  bool get railHasFocus => _state?._railScope.hasFocus ?? false;

  /// 电视用顶部标签栏（返回键逻辑不同）
  bool get topBar => _state?._topBar ?? false;

  void focusContent() => _state?.focusContent();

  void focusRail() => _state?.focusRail();
}
