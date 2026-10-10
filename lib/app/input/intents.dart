import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 统一的输入意图（docs/07-input-control.md §1）。
/// 遥控器、键盘、手柄先映射到这些意图，页面只处理意图。
class BackIntent extends Intent {
  const BackIntent();
}

class MenuIntent extends Intent {
  const MenuIntent();
}

class SearchIntent extends Intent {
  const SearchIntent();
}

/// Windows 全屏切换（F11）
class FullScreenIntent extends Intent {
  const FullScreenIntent();
}

/// 全局快捷键表。确认键（OK / Enter / A）不在这里：
/// 由 VFocusable 自己处理，以便区分短按（执行）和长按（菜单）。
const Map<ShortcutActivator, Intent> appShortcuts = <ShortcutActivator, Intent>{
  // 方向
  SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(TraversalDirection.up),
  SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(TraversalDirection.down),
  SingleActivator(LogicalKeyboardKey.arrowLeft): DirectionalFocusIntent(TraversalDirection.left),
  SingleActivator(LogicalKeyboardKey.arrowRight): DirectionalFocusIntent(TraversalDirection.right),
  // 返回：遥控器返回键 / Esc / 手柄 B / Alt+←
  SingleActivator(LogicalKeyboardKey.goBack): BackIntent(),
  SingleActivator(LogicalKeyboardKey.escape): BackIntent(),
  SingleActivator(LogicalKeyboardKey.gameButtonB): BackIntent(),
  SingleActivator(LogicalKeyboardKey.browserBack): BackIntent(),
  SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): BackIntent(),
  // 菜单：遥控器菜单键 / 键盘菜单键 / Shift+F10 / 手柄 X
  SingleActivator(LogicalKeyboardKey.contextMenu): MenuIntent(),
  SingleActivator(LogicalKeyboardKey.f10, shift: true): MenuIntent(),
  SingleActivator(LogicalKeyboardKey.gameButtonX): MenuIntent(),
  // 搜索
  SingleActivator(LogicalKeyboardKey.find): SearchIntent(),
  SingleActivator(LogicalKeyboardKey.keyF, control: true): SearchIntent(),
  SingleActivator(LogicalKeyboardKey.gameButtonY): SearchIntent(),
  // 全屏
  SingleActivator(LogicalKeyboardKey.f11): FullScreenIntent(),
};

/// 确认键集合（短按执行，长按 ≥500ms 打开菜单）。
final Set<LogicalKeyboardKey> confirmKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.select,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.gameButtonA,
};
