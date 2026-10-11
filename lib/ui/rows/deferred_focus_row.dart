import 'package:flutter/widgets.dart';

import '../focus/row_focus.dart';
import 'focus_row.dart';

/// Keeps vertical navigation stable while mounting cards only near the viewport.
/// A focused row stays mounted; its index and horizontal offset survive eviction.
class DeferredFocusRow extends StatefulWidget {
  const DeferredFocusRow({
    super.key,
    required this.rowIndex,
    required this.scrollController,
    required this.placeholder,
    required this.builder,
  });
  final int rowIndex;
  final ScrollController scrollController;
  final Widget placeholder;
  final Widget Function(BuildContext, FocusRowMemory) builder;

  /// Empty async rows must not leave a focus dead end.
  static void reportEmpty(BuildContext context, bool empty) {
    context.findAncestorStateOfType<_DeferredFocusRowState>()?._reportEmpty(empty);
  }

  @override
  State<DeferredFocusRow> createState() => _DeferredFocusRowState();
}

class _DeferredFocusRowState extends State<DeferredFocusRow> implements DeferredFocusRowHandle {
  final _memory = FocusRowMemory();
  late final _bridge = FocusNode(debugLabel: 'deferred-row${widget.rowIndex}', skipTraversal: true);
  final _scope = FocusNode(canRequestFocus: false, skipTraversal: true);
  RowFocusController? _controller;
  bool _active = false;
  bool _scheduled = false;
  bool _empty = false;

  void _reportEmpty(bool empty) {
    if (empty == _empty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || empty == _empty) return;
      if (empty) {
        if (_scope.hasFocus && _controller?.focusAdjacent(widget.rowIndex, forward: true) != true) {
          _controller?.focusAdjacent(widget.rowIndex, forward: false);
        }
        _controller?.unregisterDeferred(widget.rowIndex, this);
      } else {
        _controller?.registerDeferred(widget.rowIndex, this);
      }
      setState(() => _empty = empty);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller?.refreshDeferredRows();
      });
    });
  }

  @override
  int get length => 1;
  @override
  int get rememberedIndex => 0;
  @override
  FocusNode nodeAt(int index) => _bridge;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_schedule);
    _bridge.addListener(_activate);
    _scope.addListener(_schedule);
  }

  void _activate() {
    if (!_bridge.hasPrimaryFocus) return;
    if (!_active) setState(() => _active = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scope.hasFocus) return;
      Scrollable.ensureVisible(context, alignment: 0.32, duration: const Duration(milliseconds: 250));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = RowFocusScope.of(context);
    if (!identical(_controller, controller)) {
      _controller?.unregisterDeferred(widget.rowIndex, this);
      _controller = controller;
      if (!_empty) controller.registerDeferred(widget.rowIndex, this);
    }
    _schedule();
  }

  @override
  void didUpdateWidget(DeferredFocusRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_schedule);
      widget.scrollController.addListener(_schedule);
    }
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || _empty) return;
      final box = context.findRenderObject();
      final viewport = Scrollable.maybeOf(context)?.context.findRenderObject();
      if (box is! RenderBox || viewport is! RenderBox || !box.hasSize || !viewport.hasSize) return;
      final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
      // Load one nearby row; retain a wider band to avoid mount/unmount churn.
      final margin = _active ? viewport.size.height * 0.8 : 180.0;
      final wanted = _scope.hasFocus || (top < viewport.size.height + margin && top + box.size.height > -margin);
      if (wanted != _active) setState(() => _active = wanted);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void updateVisibility() => _schedule();

  @override
  void dispose() {
    widget.scrollController.removeListener(_schedule);
    _controller?.unregisterDeferred(widget.rowIndex, this);
    _bridge.dispose();
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    MediaQuery.sizeOf(context); // Recheck visibility when the viewport is resized.
    _schedule();
    return Focus(
      focusNode: _scope,
      child: Focus(
        focusNode: _bridge,
        child: Offstage(
          offstage: _empty,
          child: _active || _empty ? widget.builder(context, _memory) : widget.placeholder,
        ),
      ),
    );
  }
}
