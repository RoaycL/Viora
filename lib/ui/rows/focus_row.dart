import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../app/theme.dart';
import '../focus/row_focus.dart';
import '../focus/input_mode.dart';

typedef FocusRowItemBuilder = Widget Function(BuildContext context, int index, FocusNode node);

/// 横向滚动的一行卡片（首页 / 详情页通用）。
///
/// - 关键线滚动：焦点卡片固定在内容区左侧（x = [leading]），行内容滚动
/// - 行记忆：注册到 [RowFocusScope]，↑↓ 回到本行时恢复上次位置
/// - 聚焦时整行纵向滚到视口 [verticalAlignment] 处
class FocusRow extends StatefulWidget {
  const FocusRow({
    super.key,
    required this.rowIndex,
    required this.itemCount,
    required this.itemExtent,
    required this.height,
    required this.itemBuilder,
    this.title,
    this.trailing,
    this.gap = VSpace.rowGap,
    this.leading = VSpace.contentLeft,
    this.verticalAlignment = 0.32,
    this.onItemFocused,
  });

  final int rowIndex;
  final int itemCount;

  /// 单个元素宽度（不含间距）
  final double itemExtent;

  /// 元素区域高度（卡片 + 标题文字）
  final double height;
  final FocusRowItemBuilder itemBuilder;
  final String? title;
  final Widget? trailing;
  final double gap;
  final double leading;
  final double verticalAlignment;
  final ValueChanged<int>? onItemFocused;

  /// 为焦点放大和外发光预留的上下空间
  static const focusBleed = 28.0;

  @override
  State<FocusRow> createState() => _FocusRowState();
}

class _FocusRowState extends State<FocusRow> implements FocusRowHandle {
  final _scroll = ScrollController();
  final _nodes = <FocusNode>[];
  RowFocusController? _controller;
  int _remembered = 0;

  @override
  int get length => widget.itemCount;

  @override
  int get rememberedIndex => _remembered;

  @override
  FocusNode nodeAt(int index) {
    while (_nodes.length <= index) {
      final i = _nodes.length;
      final node = FocusNode(debugLabel: 'row${widget.rowIndex}#$i');
      node.addListener(() {
        if (node.hasPrimaryFocus) _onItemFocused(i);
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
  void didUpdateWidget(FocusRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rowIndex != widget.rowIndex) {
      _controller?.unregister(oldWidget.rowIndex, this);
      _controller?.register(widget.rowIndex, this);
    }
    if (_remembered >= widget.itemCount) _remembered = 0;
  }

  @override
  void dispose() {
    _controller?.unregister(widget.rowIndex, this);
    for (final node in _nodes) {
      node.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _onItemFocused(int index) {
    _remembered = index;
    widget.onItemFocused?.call(index);
    // 鼠标悬停 / 点击带来的焦点不滚动，布局保持不动
    if (!InputMode.shouldAutoScroll) return;

    if (_scroll.hasClients) {
      final position = _scroll.position;
      final target = (index * (widget.itemExtent + widget.gap)).clamp(0.0, position.maxScrollExtent);
      _scroll.animateTo(target, duration: VMotion.scroll, curve: Curves.easeOutCubic);
    }
    Scrollable.ensureVisible(
      context,
      alignment: widget.verticalAlignment,
      duration: VMotion.scroll,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null)
          Padding(
            padding: EdgeInsets.only(left: widget.leading, right: VSpace.safeH),
            child: Row(
              children: [
                Text(title, style: VText.rowTitle.copyWith(color: const Color(0xEBFFFFFF))),
                const Spacer(),
                ?widget.trailing,
              ],
            ),
          ),
        // 关键线左侧裁掉：已滚过的卡片不在导航栏后面露出。
        ClipRect(
          clipper: _LeftEdgeClipper(widget.leading - FocusRow.focusBleed),
          child: SizedBox(
            height: widget.height + FocusRow.focusBleed * 2,
            child: ListView.separated(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              scrollCacheExtent: const ScrollCacheExtent.pixels(1600),
              padding: EdgeInsets.fromLTRB(widget.leading, FocusRow.focusBleed, VSpace.safeH, FocusRow.focusBleed),
              itemCount: widget.itemCount,
              separatorBuilder: (_, _) => SizedBox(width: widget.gap),
              itemBuilder: (context, index) =>
                  SizedBox(width: widget.itemExtent, child: widget.itemBuilder(context, index, nodeAt(index))),
            ),
          ),
        ),
      ],
    );
  }
}

class _LeftEdgeClipper extends CustomClipper<Rect> {
  const _LeftEdgeClipper(this.left);

  final double left;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(left, -200, size.width + 200, size.height + 200);

  @override
  bool shouldReclip(_LeftEdgeClipper oldClipper) => oldClipper.left != left;
}
