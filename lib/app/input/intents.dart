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

/// Windows：`/` 打开搜索。焦点在输入框里时不生效（照常输入 /）
class SlashSearchIntent extends Intent {
  const SlashSearchIntent();
}

/// 整页翻：电视频道 +/-、键盘 PageUp / PageDown（docs/07 §2.1：网格页整页翻页）
class PageIntent extends Intent {
  const PageIntent(this.direction);
  final TraversalDirection direction;
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
  // 返回：遥控器返回键 / Esc / 手柄 B / Alt+←。按住不放不连续返回（长按 3 秒是退出确认，见 app.dart）
  SingleActivator(LogicalKeyboardKey.goBack, includeRepeats: false): BackIntent(),
  SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): BackIntent(),
  SingleActivator(LogicalKeyboardKey.gameButtonB, includeRepeats: false): BackIntent(),
  SingleActivator(LogicalKeyboardKey.browserBack, includeRepeats: false): BackIntent(),
  SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): BackIntent(),
  // 菜单：遥控器菜单键 / 键盘菜单键 / Shift+F10 / 手柄 X
  SingleActivator(LogicalKeyboardKey.contextMenu): MenuIntent(),
  SingleActivator(LogicalKeyboardKey.f10, shift: true): MenuIntent(),
  SingleActivator(LogicalKeyboardKey.gameButtonX): MenuIntent(),
  // 搜索
  SingleActivator(LogicalKeyboardKey.find): SearchIntent(),
  SingleActivator(LogicalKeyboardKey.keyF, control: true): SearchIntent(),
  SingleActivator(LogicalKeyboardKey.gameButtonY): SearchIntent(),
  SingleActivator(LogicalKeyboardKey.slash): SlashSearchIntent(),
  // 整页翻
  SingleActivator(LogicalKeyboardKey.channelUp): PageIntent(TraversalDirection.up),
  SingleActivator(LogicalKeyboardKey.channelDown): PageIntent(TraversalDirection.down),
  SingleActivator(LogicalKeyboardKey.pageUp): PageIntent(TraversalDirection.up),
  SingleActivator(LogicalKeyboardKey.pageDown): PageIntent(TraversalDirection.down),
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

/// `/` 搜索：焦点在输入框里时不处理（按键照常交给输入框）
class SlashSearchAction extends Action<SlashSearchIntent> {
  SlashSearchAction(this.onSearch);

  final VoidCallback onSearch;

  @override
  bool isEnabled(SlashSearchIntent intent) =>
      FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() == null &&
      FocusManager.instance.primaryFocus?.context?.widget is! EditableText;

  @override
  Object? invoke(SlashSearchIntent intent) {
    onSearch();
    return null;
  }
}

/// 整页翻：沿方向连续移动 [rows] 次焦点，每次等一帧（网格是懒加载的，下面的卡片移过去时才建出来）
class PageAction extends Action<PageIntent> {
  PageAction({this.rows = 3});

  final int rows;

  @override
  Future<void> invoke(PageIntent intent) async {
    for (var i = 0; i < rows; i++) {
      final node = FocusManager.instance.primaryFocus;
      final context = node?.context;
      if (node == null || context == null || !context.mounted) return;
      Actions.maybeInvoke(context, DirectionalFocusIntent(intent.direction));
      // 焦点变化在微任务里生效；等这一帧画完（懒加载的下一行建出来）再走下一步
      await WidgetsBinding.instance.endOfFrame;
      if (identical(FocusManager.instance.primaryFocus, node)) return; // 到头了
    }
  }
}
