import 'dart:async';

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

  /// 电视：焦点停在标签上一会儿就切到那个页面（不用按 OK）；快速划过的标签不切，免得每个页面都去请求服务器
  static const tabSwitchDelay = Duration(milliseconds: 280);
  Timer? _tabTimer;

  /// 正在用标签栏浏览页面：新页面的自动聚焦（首页的播放按钮、资源库第一台服务器……）不能把焦点从标签栏拿走，
  /// 按 ↓ / OK 进入内容时结束
  NavItem? _browsing;

  @override
  void initState() {
    super.initState();
    ShellController.instance._attach(this);
    _railScope.addListener(_onBarFocus);
    FocusManager.instance.addListener(_onFocusChange);
    if (_topBar) {
      for (final item in NavItem.values) {
        final node = _railNodes[item.path]!;
        node.addListener(() {
          if (node.hasPrimaryFocus) _onTabFocus(item);
        });
      }
    }
  }

  /// 搜索不跟着焦点切换：搜索页打开时焦点进输入框，电视上可能弹出输入法，仍然按 OK 进入
  void _onTabFocus(NavItem item) {
    _tabTimer?.cancel();
    if (item == NavItem.search) return;
    _tabTimer = Timer(tabSwitchDelay, () {
      if (!mounted || !_railNodes[item.path]!.hasPrimaryFocus) return;
      _browsing = item;
      if (item != _active) context.go(item.path);
    });
  }

  /// 焦点落在内容区的空容器上（页面路由打开时会把焦点拿到自己的 FocusScope 上；页面还在加载、
  /// 没有可聚焦的控件时就停在那里，方向键没有反应）：把焦点还给当前导航项，可以继续切换
  void _onFocusChange() {
    final primary = FocusManager.instance.primaryFocus;
    final inContent = primary != null && (primary == _contentScope || primary.ancestors.contains(_contentScope));
    final browsing = _browsing;
    if (browsing != null) {
      if (inContent) {
        // 用标签栏浏览时新页面自己抢走了焦点：还给标签
        scheduleMicrotask(() {
          if (mounted && _browsing == browsing) _railNodes[browsing.path]?.requestFocus();
        });
        return;
      }
      // 焦点去了标签栏、内容区以外的地方（弹窗、详情页……）：不再拦
      if (primary == null || !primary.ancestors.contains(_railScope)) _browsing = null;
    }
    if (primary is! FocusScopeNode || !inContent) return;
    if (_hasFocusableContent) return;
    scheduleMicrotask(() {
      if (!mounted || FocusManager.instance.primaryFocus != primary || _hasFocusableContent) return;
      _railNodes[_active.path]?.requestFocus();
    });
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
    _tabTimer?.cancel();
    _railScope.removeListener(_onBarFocus);
    FocusManager.instance.removeListener(_onFocusChange);
    _railScope.dispose();
    _contentScope.dispose();
    for (final node in _railNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  NavItem get _active => NavItem.forLocation(widget.location);

  void focusRail() => _railNodes[_active.path]!.requestFocus();

  /// 回到内容区上次的焦点；页面还没有可聚焦的内容（加载中、空列表）时不动，焦点留在导航上，
  /// 可以继续切换（不然焦点落在页面的空容器上，方向键回不到导航，要等加载完才能动）
  void focusContent() {
    // 上次的焦点（通常是页面的 FocusScope，由它恢复具体控件；首页的卡片被回收时由首页按作品找回）
    final last = _contentScope.focusedChild;
    if (!_hasFocusableContent) return;
    _browsing = null;
    _tabTimer?.cancel();
    if (last is FocusScopeNode && last.context != null && last.focusedChild == null) {
      // 页面还没有聚焦过任何控件（加载完之前焦点一直在导航上）：进入它的第一个控件
      last.requestFocus();
      last.nextFocus();
    } else if (last != null && last.context != null) {
      last.requestFocus();
    } else {
      _contentScope.requestFocus();
      _contentScope.nextFocus();
    }
  }

  /// 只看当前页面：切换后同一帧里上一个页面还在树上（转场完成后才移除）
  bool get _hasFocusableContent => _contentScope.traversalDescendants.any((n) {
    final context = n.context;
    return n is! FocusScopeNode && context != null && (ModalRoute.of(context)?.isCurrent ?? true);
  });

  void _select(NavItem item) {
    _browsing = null;
    _tabTimer?.cancel();
    if (item != _active) context.go(item.path);
    // 选中后进入内容区；新页面的 autofocus 会接管焦点。
    // 新页面还没有可聚焦的内容（收藏、观看记录加载中）：焦点回到刚选的导航项，可以继续切换，
    // 页面在后台加载，加载完按 ↓ / → 进入（新页面打开时路由会把焦点拿到它的空容器上）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_hasFocusableContent) {
        focusContent();
      } else {
        _railNodes[item.path]?.requestFocus();
      }
    });
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
            // 方向键处理放在 FocusScope 外层：焦点落在页面的空容器（FocusScope 本身）上时也能处理
            Positioned.fill(
              child: Actions(
                actions: <Type, Action<Intent>>{
                  DirectionalFocusIntent: EdgeAwareDirectionalAction((direction) {
                    if (direction == toBar) focusRail();
                    return true;
                  }),
                },
                child: FocusScope(
                  node: _contentScope,
                  child: NotificationListener<ScrollNotification>(onNotification: _onScroll, child: widget.child),
                ),
              ),
            ),
            Actions(
              actions: <Type, Action<Intent>>{
                DirectionalFocusIntent: EdgeAwareDirectionalAction((direction) {
                  if (direction == toContent) focusContent();
                  return true;
                }),
              },
              child: FocusScope(node: _railScope, child: nav),
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
