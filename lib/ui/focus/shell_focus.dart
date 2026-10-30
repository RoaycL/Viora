import 'package:flutter/widgets.dart';

/// 应用壳的两个焦点区域：导航（Windows 左侧导航栏 / 电视顶部标签栏）与内容区。
///
/// 两者都是独立的 FocusScope，方向键默认不会跨区域移动；
/// 跨区域由这里显式处理：Windows 内容区最左侧再按 ← 进入导航栏的当前项，按 → 回来；
/// 电视在内容第一行按 ↑ 进入标签栏，按 ↓ 回来。回到内容区时恢复上次的焦点（FocusScope 自带记忆）。
class ShellFocus extends InheritedWidget {
  const ShellFocus({
    super.key,
    required this.focusRail,
    required this.focusContent,
    this.topBar = false,
    required super.child,
  });

  final VoidCallback focusRail;
  final VoidCallback focusContent;

  /// 导航在顶部（电视）：↑ 进入导航，最左侧按 ← 不再进入导航
  final bool topBar;

  static ShellFocus? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<ShellFocus>();

  @override
  bool updateShouldNotify(ShellFocus oldWidget) => false;
}

/// 在某个 FocusScope 内按方向移动焦点；移不动时调用 [onEdge]。
class EdgeAwareDirectionalAction extends Action<DirectionalFocusIntent> {
  EdgeAwareDirectionalAction(this.onEdge);

  final bool Function(TraversalDirection direction) onEdge;

  @override
  Object? invoke(DirectionalFocusIntent intent) {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return null;
    final moved = focus.focusInDirection(intent.direction);
    if (!moved) onEdge(intent.direction);
    return null;
  }
}
