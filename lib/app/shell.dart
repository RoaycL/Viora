import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../ui/focus/shell_focus.dart';
import '../ui/nav/side_nav_rail.dart';
import 'theme.dart';

/// 应用壳：左侧导航栏 + 内容区，两者是独立的焦点区域。
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

  @override
  void initState() {
    super.initState();
    ShellController.instance._attach(this);
  }

  @override
  void dispose() {
    ShellController.instance._detach(this);
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

  @override
  Widget build(BuildContext context) {
    return ShellFocus(
      focusRail: focusRail,
      focusContent: focusContent,
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
                      if (direction == TraversalDirection.left) focusRail();
                      return true;
                    }),
                  },
                  child: widget.child,
                ),
              ),
            ),
            FocusScope(
              node: _railScope,
              child: Actions(
                actions: <Type, Action<Intent>>{
                  DirectionalFocusIntent: EdgeAwareDirectionalAction((direction) {
                    if (direction == TraversalDirection.right) focusContent();
                    return true;
                  }),
                },
                child: SideNavRail(
                  active: _active,
                  nodes: _railNodes,
                  scope: _railScope,
                  onPointerLeave: focusContent,
                  onSelect: (item) {
                    if (item != _active) context.go(item.path);
                    // 选中后进入内容区；新页面的 autofocus 会接管焦点。
                    WidgetsBinding.instance.addPostFrameCallback((_) => focusContent());
                  },
                ),
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

  void focusContent() => _state?.focusContent();
}
