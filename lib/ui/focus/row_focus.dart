import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;

import '../../app/theme.dart';

import 'shell_focus.dart';
import 'input_mode.dart';

/// 一行可聚焦元素。行可以是横向滚动的卡片行，也可以是一组按钮。
abstract class FocusRowHandle {
  int get length;
  FocusNode nodeAt(int index);

  /// 该行上次聚焦的位置（Netflix 式行记忆）。
  int get rememberedIndex;
}

/// 按需构建的横排先挂载目标卡片，再由页面确认本次导航仍然有效后请求焦点。
abstract interface class RevealableFocusRow implements FocusRowHandle {
  Future<FocusNode?> revealNode(int index);
  int? indexOfNode(FocusNode node);
}

/// 管理一个页面上的所有行（docs/07-input-control.md §2.2）：
/// ↑↓ 在行之间移动并恢复行记忆，←→ 在行内移动，最左再按 ← 交给应用壳（进入导航栏）。
class RowFocusController {
  final Map<int, FocusRowHandle> _rows = <int, FocusRowHandle>{};

  FocusRowHandle? rowAt(int rowIndex) => _rows[rowIndex];

  void register(int rowIndex, FocusRowHandle row) => _rows[rowIndex] = row;

  void unregister(int rowIndex, FocusRowHandle row) {
    if (identical(_rows[rowIndex], row)) _rows.remove(rowIndex);
  }

  List<int> get _sortedRows => _rows.keys.toList()..sort();

  ({int row, int index})? locate(FocusNode? node) {
    if (node == null) return null;
    for (final entry in _rows.entries) {
      final row = entry.value;
      if (row is RevealableFocusRow) {
        final index = row.indexOfNode(node);
        if (index != null) return (row: entry.key, index: index);
        continue;
      }
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
  const RowFocusScope({super.key, required this.child, this.controller});

  final Widget child;
  final RowFocusController? controller;

  static RowFocusController of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_RowFocusInherited>()!.controller;

  @override
  State<RowFocusScope> createState() => _RowFocusScopeState();
}

class _RowFocusScopeState extends State<RowFocusScope> {
  late final _ownController = RowFocusController();
  RowFocusController get _controller => widget.controller ?? _ownController;

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
  bool updateShouldNotify(_RowFocusInherited oldWidget) => !identical(controller, oldWidget.controller);
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
  const FocusButtonRow({
    super.key,
    required this.rowIndex,
    required this.children,
    this.spacing = 18,
    this.autoScroll = true,
    this.scrollToTop = false,
    this.scrollable = false,
    this.itemKeys,
  }) : assert(itemKeys == null || itemKeys.length == children.length);

  /// 获得焦点时把页面滚回最顶部（详情页的第一行按钮：上面的 Logo、标题、简介要完整露出来）
  final bool scrollToTop;

  /// 有宽度约束的详情操作/季选择，焦点移动时只横向露出当前按钮。
  final bool scrollable;

  /// 异步插入/删除操作时，以动作身份保留节点、按键状态与行记忆。
  final List<Object>? itemKeys;

  /// 获得焦点时把按钮行滚到视口约 30% 处；页面顶部的按钮行（如首页引导）不需要
  final bool autoScroll;

  final int rowIndex;
  final List<Widget Function(FocusNode node)> children;
  final double spacing;

  @override
  State<FocusButtonRow> createState() => _FocusButtonRowState();
}

class _FocusButtonRowState extends State<FocusButtonRow> implements FocusRowHandle {
  final _nodes = <Object, FocusNode>{};
  RowFocusController? _controller;
  int _remembered = 0;

  @override
  int get length => widget.children.length;

  @override
  int get rememberedIndex => _remembered;

  @override
  FocusNode nodeAt(int index) {
    final key = widget.itemKeys?[index] ?? index;
    return _nodes.putIfAbsent(key, () {
      final node = FocusNode(debugLabel: 'buttons${widget.rowIndex}#$index');
      node.addListener(() {
        final i = widget.itemKeys?.indexOf(key) ?? index;
        if (node.hasPrimaryFocus && i >= 0 && i < length) {
          _remembered = i;
          if (InputMode.shouldAutoScroll && widget.scrollable) {
            final ctx = node.context;
            final box = ctx?.findRenderObject();
            final horizontal = ctx == null ? null : Scrollable.maybeOf(ctx, axis: Axis.horizontal);
            if (box != null && horizontal != null) {
              final start = RenderAbstractViewport.of(box).getOffsetToReveal(box, 0).offset;
              horizontal.position.ensureVisible(
                box,
                duration: VMotion.duration(context, VMotion.scroll),
                alignmentPolicy: start < horizontal.position.pixels
                    ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
                    : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
              );
            }
          }
          if (InputMode.shouldAutoScroll && widget.scrollToTop) {
            final pos = Scrollable.maybeOf(context, axis: Axis.vertical)?.position;
            if (pos != null) {
              final box = context.findRenderObject();
              final end = box == null ? 0 : RenderAbstractViewport.of(box).getOffsetToReveal(box, 1).offset;
              if (widget.scrollable && end > 0 && box != null) {
                // 放大文字令首屏增高时，先保证按钮可见，不把焦点滚到屏外。
                pos.ensureVisible(
                  box,
                  duration: VMotion.duration(context, VMotion.scroll),
                  alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
                );
              } else if (pos.pixels > 0) {
                if (VMotion.reduced(context)) {
                  pos.jumpTo(0);
                } else {
                  pos.animateTo(0, duration: VMotion.scroll, curve: Curves.easeOutCubic);
                }
              }
            }
          } else if (InputMode.shouldAutoScroll && widget.autoScroll) {
            Scrollable.ensureVisible(context, alignment: 0.3, duration: VMotion.duration(context, VMotion.scroll));
          }
        }
      });
      return node;
    });
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
  void didUpdateWidget(FocusButtonRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final key = oldWidget.itemKeys == null || _remembered >= oldWidget.children.length
        ? null
        : oldWidget.itemKeys![_remembered];
    final index = key == null ? -1 : widget.itemKeys?.indexOf(key) ?? -1;
    if (index >= 0) _remembered = index;
    if (oldWidget.rowIndex != widget.rowIndex) {
      _controller?.unregister(oldWidget.rowIndex, this);
      _controller?.register(widget.rowIndex, this);
    }
  }

  @override
  void dispose() {
    _controller?.unregister(widget.rowIndex, this);
    for (final n in _nodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_remembered >= length) _remembered = 0;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < length; i++) ...[
          if (i > 0) SizedBox(width: widget.spacing),
          if (widget.itemKeys == null)
            widget.children[i](nodeAt(i))
          else
            KeyedSubtree(key: ValueKey(widget.itemKeys![i]), child: widget.children[i](nodeAt(i))),
        ],
      ],
    );
    return widget.scrollable
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: row,
          )
        : row;
  }
}
