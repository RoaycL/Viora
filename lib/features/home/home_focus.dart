import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';

import '../../ui/focus/input_mode.dart';
import '../../ui/focus/row_focus.dart';

/// 首页的逻辑行独立于当前挂载的行；记忆只保存作品身份，不持有离屏图片或 FocusNode。
class HomeFocusController extends RowFocusController {
  HomeFocusController({required this.anchor, required this.revealRow}) {
    FocusManager.instance.addListener(_observeFocus);
  }

  final FocusNode anchor;
  final Future<void> Function(int row) revealRow;
  List<int> _order = const [];
  List<int> get order => _order;
  set order(List<int> rows) {
    final changed = !listEquals(_order, rows);
    _order = rows;
    if (!changed || rows.isEmpty || !anchor.hasFocus) return;
    if (_pendingRow != null && !rows.contains(_pendingRow)) {
      final next = rows.where((r) => r >= _pendingRow!).firstOrNull ?? rows.last;
      _scheduleRow(next, 0);
      return;
    }
    if (navigating) return;
    if (!rows.contains(_activeRow)) {
      final next = rows.where((r) => r >= _activeRow).firstOrNull ?? rows.last;
      _scheduleRow(next, 0);
    } else if (!InputMode.pointer) {
      _scheduleRow(_activeRow, _remembered[_activeRow]?.index ?? 0);
    }
  }

  final _items = <int, List<Object>>{};
  final _remembered = <int, ({Object? key, int index})>{};
  int _activeRow = 0;
  int? _pendingRow;
  int? _pendingIndex;
  FocusNode? _pendingNode;
  int _generation = 0;
  bool _disposed = false;

  bool get atHero => _activeRow == 0 && _pendingRow == null;
  bool get navigating => _pendingRow != null;

  void cancelNavigation() {
    _generation++;
    _pendingRow = _pendingIndex = null;
    _pendingNode = null;
  }

  void resetMemory() {
    cancelNavigation();
    _items.clear();
    _remembered.clear();
    _activeRow = 0;
  }

  int updateItems(int row, List<Object> keys) {
    final old = _remembered[row];
    final index = old?.key == null ? -1 : keys.indexOf(old!.key!);
    final resolved = keys.isEmpty
        ? 0
        : index >= 0
        ? index
        : (old?.index ?? 0).clamp(0, keys.length - 1);
    final changed = old != null && !listEquals(_items[row], keys);
    _items[row] = keys;
    if (keys.isNotEmpty) _remembered[row] = (key: keys[resolved], index: resolved);
    if (keys.isNotEmpty && (changed || rowAt(row) is! RevealableFocusRow)) preserveRow(row, index: resolved);
    return resolved;
  }

  /// 移除旧控件前保留导航意图，防止框架先回退到上一行并覆盖逻辑位置。
  void preserveRow(int row, {int? index}) {
    if (_activeRow != row ||
        navigating ||
        !anchor.hasFocus ||
        super.locate(FocusManager.instance.primaryFocus)?.row != row) {
      return;
    }
    _scheduleRow(row, index ?? _remembered[row]?.index ?? 0);
  }

  void _scheduleRow(int row, int index) {
    final generation = ++_generation;
    _pendingRow = row;
    _pendingIndex = index;
    _pendingNode = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusManager.instance.applyFocusChangesIfNeeded();
      if (_valid(generation)) _focus(row, generation);
    });
  }

  bool remember(int row, int index) {
    if (navigating && _pendingRow != row) return false;
    _activeRow = row;
    final keys = _items[row];
    _remembered[row] = (key: keys != null && index < keys.length ? keys[index] : null, index: index);
    return true;
  }

  void enteredRow(int row) {
    if (!navigating || _pendingRow == row) _activeRow = row;
  }

  bool _valid(int generation) => !_disposed && generation == _generation && anchor.hasFocus;

  void _observeFocus() {
    if (_disposed) return;
    final node = FocusManager.instance.primaryFocus;
    if (node == null || (node != anchor && !node.ancestors.contains(anchor))) {
      cancelNavigation();
    } else if (node == _pendingNode) {
      _pendingRow = _pendingIndex = null;
      _pendingNode = null;
    } else if (node == anchor && !navigating && !InputMode.pointer) {
      focusRow(order.contains(_activeRow) ? _activeRow : 0);
    }
  }

  @override
  void register(int rowIndex, FocusRowHandle row) {
    final previous = rowAt(rowIndex);
    final replacingFocused = previous != null && super.locate(FocusManager.instance.primaryFocus)?.row == rowIndex;
    super.register(rowIndex, row);
    if (replacingFocused && !navigating) {
      final generation = _generation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_valid(generation) && _activeRow == rowIndex) focusRow(rowIndex);
      });
    }
  }

  @override
  bool focusRow(int rowIndex, {int? index}) {
    if (_disposed || !order.contains(rowIndex)) return false;
    final generation = ++_generation;
    _pendingRow = rowIndex;
    _pendingIndex = index ?? _remembered[rowIndex]?.index ?? rowAt(rowIndex)?.rememberedIndex ?? 0;
    _pendingNode = null;
    _focus(rowIndex, generation);
    return true;
  }

  Future<void> _focus(int rowIndex, int generation) async {
    await revealRow(rowIndex);
    if (!_valid(generation)) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!_valid(generation)) return;
    final row = rowAt(rowIndex);
    if (row == null || row.length == 0) {
      cancelNavigation();
      return;
    }
    final index = (_pendingIndex ?? 0).clamp(0, row.length - 1);
    final node = row is RevealableFocusRow ? await row.revealNode(index) : row.nodeAt(index);
    if (!_valid(generation)) return;
    if (node?.context == null) {
      cancelNavigation();
      return;
    }
    _pendingNode = node;
    _activeRow = rowIndex;
    node!.requestFocus();
    if (node.hasPrimaryFocus) {
      _pendingRow = _pendingIndex = null;
      _pendingNode = null;
    }
  }

  @override
  bool move(FocusNode? current, TraversalDirection direction) {
    final located = super.locate(current);
    if (located == null && current != anchor && !navigating) return false;
    final row = _pendingRow ?? located?.row ?? _activeRow;
    final index = _pendingIndex ?? located?.index ?? _remembered[row]?.index ?? 0;
    if (direction == TraversalDirection.left || direction == TraversalDirection.right) {
      if (direction == TraversalDirection.left && index == 0) {
        cancelNavigation();
        return false;
      }
      final length = rowAt(row)?.length ?? _items[row]?.length ?? 1;
      final target = (index + (direction == TraversalDirection.right ? 1 : -1)).clamp(0, length - 1);
      // 行内移动且目标卡片已挂载：同步换焦点。走异步路径要等一帧，长按时每次按键都会取消上一次，
      // 焦点停住直到松手才跳过去
      if (!navigating && located?.row == row && _focusMounted(row, target)) return true;
      focusRow(row, index: target);
      return true;
    }
    final at = order.indexOf(row);
    final next = at + (direction == TraversalDirection.down ? 1 : -1);
    if (at >= 0 && next >= 0 && next < order.length) focusRow(order[next]);
    return true;
  }

  bool _focusMounted(int row, int index) {
    final handle = rowAt(row);
    if (handle == null || index >= handle.length) return false;
    final node = handle.nodeAt(index);
    if (node.context?.mounted != true || !node.canRequestFocus) return false;
    _generation++;
    _activeRow = row;
    node.requestFocus();
    return true;
  }

  void dispose() {
    _disposed = true;
    cancelNavigation();
    FocusManager.instance.removeListener(_observeFocus);
  }
}

/// 只保留正在持有焦点的一行，避免滚动销毁焦点；其余离屏行可以正常回收。
class HomeFocusSlot extends StatefulWidget {
  const HomeFocusSlot({super.key, required this.row, required this.controller, required this.child});
  final int row;
  final HomeFocusController controller;
  final Widget child;

  @override
  State<HomeFocusSlot> createState() => _HomeFocusSlotState();
}

class _HomeFocusSlotState extends State<HomeFocusSlot> with AutomaticKeepAliveClientMixin {
  bool _focused = false;
  @override
  bool get wantKeepAlive => _focused;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        if (_focused == focused) return;
        _focused = focused;
        if (focused) widget.controller.enteredRow(widget.row);
        updateKeepAlive();
      },
      child: widget.child,
    );
  }
}
