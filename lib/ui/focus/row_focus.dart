import 'package:flutter/widgets.dart';

import 'shell_focus.dart';

/// 一行可聚焦元素。行可以是横向滚动的卡片行，也可以是一组按钮。
abstract class FocusRowHandle {
  int get length;
  FocusNode nodeAt(int index);

  /// 该行上次聚焦的位置（Netflix 式行记忆）。
  int get rememberedIndex;
}

/// 管理一个页面上的所有行（docs/07-input-control.md §2.2）：
/// ↑↓ 在行之间移动并恢复行记忆，←→ 在行内移动，最左再按 ← 交给应用壳（进入导航栏）。
class RowFocusController {
  final Map<int, FocusRowHandle> _rows = <int, FocusRowHandle>{};

  void register(int rowIndex, FocusRowHandle row) => _rows[rowIndex] = row;

  void unregister(int rowIndex, FocusRowHandle row) {
    if (identical(_rows[rowIndex], row)) _rows.remove(rowIndex);
  }

  List<int> get _sortedRows => _rows.keys.toList()..sort();

  ({int row, int index})? locate(FocusNode? node) {
    if (node == null) return null;
    for (final entry in _rows.entries) {
      final row = entry.value;
      for (var i = 0; i < row.length; i++) {
        if (identical(row.nodeAt(i), node)) return (row: entry.key, index: i);
      }
    }
    return null;
  }

  bool focusRow(int rowIndex, {int? index}) {
    final row = _rows[rowIndex];
    if (row == null || row.length == 0) return false;
    final i = (index ?? row.rememberedIndex).clamp(0, row.length - 1);
    row.nodeAt(i).requestFocus();
    return true;
  }

  /// 返回 true 表示已处理。
  bool move(FocusNode? current, TraversalDirection direction) {
    final pos = locate(current);
    if (pos == null) return false;
    final row = _rows[pos.row]!;
    switch (direction) {
      case TraversalDirection.left:
        if (pos.index == 0) return false;
        row.nodeAt(pos.index - 1).requestFocus();
        return true;
      case TraversalDirection.right:
        // 行尾不再移动，也不让焦点"掉"到别处。
        if (pos.index < row.length - 1) row.nodeAt(pos.index + 1).requestFocus();
        return true;
      case TraversalDirection.up:
      case TraversalDirection.down:
        final rows = _sortedRows;
        final at = rows.indexOf(pos.row);
        final step = direction == TraversalDirection.down ? 1 : -1;
        for (var i = at + step; i >= 0 && i < rows.length; i += step) {
          if (focusRow(rows[i])) return true;
        }
        return true;
    }
  }
}

/// 给子树提供 [RowFocusController]，并接管方向键。
class RowFocusScope extends StatefulWidget {
  const RowFocusScope({super.key, required this.child});

  final Widget child;

  static RowFocusController of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_RowFocusInherited>()!.controller;

  @override
  State<RowFocusScope> createState() => _RowFocusScopeState();
}

class _RowFocusScopeState extends State<RowFocusScope> {
  final _controller = RowFocusController();

  @override
  Widget build(BuildContext context) {
    return _RowFocusInherited(
      controller: _controller,
      child: Actions(
        actions: <Type, Action<Intent>>{
          DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
            onInvoke: (intent) {
              final focus = FocusManager.instance.primaryFocus;
              if (_controller.move(focus, intent.direction)) return null;
              if (intent.direction == TraversalDirection.left) {
                ShellFocus.maybeOf(context)?.focusRail();
              } else {
                focus?.focusInDirection(intent.direction);
              }
              return null;
            },
          ),
        },
        child: widget.child,
      ),
    );
  }
}

class _RowFocusInherited extends InheritedWidget {
  const _RowFocusInherited({required this.controller, required super.child});

  final RowFocusController controller;

  @override
  bool updateShouldNotify(_RowFocusInherited oldWidget) => false;
}
