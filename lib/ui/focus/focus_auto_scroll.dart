import 'package:flutter/widgets.dart';

import '../../app/theme.dart';
import 'input_mode.dart';

/// 表单 / 设置这类纵向页面：焦点移动到哪，就把它滚到视口中部（遥控器没有触摸滚动）。
class FocusAutoScroll extends StatefulWidget {
  const FocusAutoScroll({super.key, required this.child, this.alignment = 0.4});

  final Widget child;
  final double alignment;

  @override
  State<FocusAutoScroll> createState() => _FocusAutoScrollState();
}

class _FocusAutoScrollState extends State<FocusAutoScroll> {
  final _marker = FocusNode(debugLabel: 'FocusAutoScroll', canRequestFocus: false, skipTraversal: true);
  FocusNode? _last;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocus);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocus);
    _marker.dispose();
    super.dispose();
  }

  void _onFocus() {
    final node = FocusManager.instance.primaryFocus;
    if (node == null || identical(node, _last) || !node.ancestors.contains(_marker)) return;
    if (!InputMode.shouldAutoScroll) {
      _last = node;
      return;
    }
    _last = node;
    final ctx = node.context;
    if (ctx == null || !ctx.mounted) return;
    Scrollable.ensureVisible(ctx, alignment: widget.alignment, duration: VMotion.scroll);
  }

  @override
  Widget build(BuildContext context) => Focus(focusNode: _marker, child: widget.child);
}
