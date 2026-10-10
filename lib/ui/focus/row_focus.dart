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

  /// 聚焦最上面一个有内容的行
  bool focusFirst() {
    for (final r in _sortedRows) {
      if (focusRow(r)) return true;
    }
    return false;
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

/// 放在 [RowFocusScope] 内：首次构建后，如果页面里还没有焦点，就聚焦最上面的一行。
/// 用于数据异步加载、第一行不固定的页面。
class RowAutoFocus extends StatefulWidget {
  const RowAutoFocus({super.key});

  @override
  State<RowAutoFocus> createState() => _RowAutoFocusState();
}

class _RowAutoFocusState extends State<RowAutoFocus> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = RowFocusScope.of(context);
      final current = FocusManager.instance.primaryFocus;
      if (current == null || controller.locate(current) == null) controller.focusFirst();
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 一行按钮（详情页操作按钮等），参与行导航。
class FocusButtonRow extends StatefulWidget {
  const FocusButtonRow({super.key, required this.rowIndex, required this.children, this.spacing = 18});

  final int rowIndex;
  final List<Widget Function(FocusNode node)> children;
  final double spacing;

  @override
  State<FocusButtonRow> createState() => _FocusButtonRowState();
}

class _FocusButtonRowState extends State<FocusButtonRow> implements FocusRowHandle {
  final _nodes = <FocusNode>[];
  RowFocusController? _controller;
  int _remembered = 0;

  @override
  int get length => widget.children.length;

  @override
  int get rememberedIndex => _remembered;

  @override
  FocusNode nodeAt(int index) {
    while (_nodes.length <= index) {
      final i = _nodes.length;
      final node = FocusNode(debugLabel: 'buttons${widget.rowIndex}#$i');
      node.addListener(() {
        if (node.hasPrimaryFocus) {
          _remembered = i;
          Scrollable.ensureVisible(context, alignment: 0.3, duration: const Duration(milliseconds: 250));
        }
      });
      _nodes.add(node);
    }
    return _nodes[index];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = RowFocusScope.of(context);
    if (!identical(controller, _controller)) {
      _controller?.unregister(widget.rowIndex, this);
      _controller = controller..register(widget.rowIndex, this);
    }
  }

  @override
  void dispose() {
    _controller?.unregister(widget.rowIndex, this);
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_remembered >= length) _remembered = 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < length; i++) ...[if (i > 0) SizedBox(width: widget.spacing), widget.children[i](nodeAt(i))],
      ],
    );
  }
}
