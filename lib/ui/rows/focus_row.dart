import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../../app/platform_profile.dart';
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
    this.initialIndex = 0,
    this.itemKeys,
    this.autoScrollVertical = true,
    this.forwardShiftWheelAtEdge = false,
  });

  /// 初始位置：行一出现就滚到这一项，↓ 进入本行时焦点也落在这里（如详情页当前看到的那一集）
  final int initialIndex;
  final List<Object>? itemKeys;
  final bool autoScrollVertical;
  final bool forwardShiftWheelAtEdge;

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

class _FocusRowState extends State<FocusRow> implements RevealableFocusRow {
  late final ScrollController _scroll;
  final _nodes = <Object, FocusNode>{};
  RowFocusController? _controller;
  int _remembered = 0;

  @override
  int get length => widget.itemCount;

  @override
  int get rememberedIndex => _remembered;

  @override
  FocusNode nodeAt(int index) {
    final key = widget.itemKeys?[index] ?? index;
    return _nodes.putIfAbsent(key, () {
      final node = FocusNode(debugLabel: 'row${widget.rowIndex}#$index');
      node.addListener(() {
        final i = widget.itemKeys?.indexOf(key) ?? index;
        if (node.hasPrimaryFocus && i >= 0 && i < widget.itemCount) _onItemFocused(i);
      });
      return node;
    });
  }

  @override
  Future<FocusNode?> revealNode(int index) async {
    if (!mounted || index < 0 || index >= length) return null;
    var node = nodeAt(index);
    if (node.context != null) return node;
    if (!_scroll.hasClients) return null;
    _scroll.jumpTo((index * (widget.itemExtent + widget.gap)).clamp(0.0, _scroll.position.maxScrollExtent));
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || index >= length) return null;
    node = nodeAt(index);
    return node.context == null ? null : node;
  }

  @override
  int? indexOfNode(FocusNode node) {
    for (final entry in _nodes.entries) {
      if (!identical(entry.value, node)) continue;
      final index = widget.itemKeys?.indexOf(entry.key) ?? entry.key as int;
      return index >= 0 && index < length ? index : null;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _remembered = widget.itemCount == 0 ? 0 : widget.initialIndex.clamp(0, widget.itemCount - 1);
    _scroll = ScrollController(
      initialScrollOffset: _remembered * (widget.itemExtent + widget.gap),
      keepScrollOffset: widget.itemKeys == null,
    );
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
    final keys = widget.itemKeys;
    if (keys != null && !listEquals(oldWidget.itemKeys, keys)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final retired = _nodes.keys.where((k) => !widget.itemKeys!.contains(k) && _nodes[k]!.context == null).toList();
        for (final key in retired) {
          _nodes.remove(key)?.dispose();
        }
      });
    }
  }

  @override
  void dispose() {
    _controller?.unregister(widget.rowIndex, this);
    for (final node in _nodes.values) {
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
      if (VMotion.reduced(context)) {
        _scroll.jumpTo(target);
      } else {
        _scroll.animateTo(target, duration: VMotion.scroll, curve: Curves.easeOutCubic);
      }
    }
    if (widget.autoScrollVertical) {
      Scrollable.ensureVisible(
        context,
        alignment: widget.verticalAlignment,
        duration: VMotion.duration(context, VMotion.scroll),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _forwardEdgeScroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.kind != PointerDeviceKind.mouse || !_scroll.hasClients) return;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    if (!keys.contains(LogicalKeyboardKey.shiftLeft) && !keys.contains(LogicalKeyboardKey.shiftRight)) return;
    final delta = event.scrollDelta.dy;
    final row = _scroll.position;
    if (delta == 0 || (row.pixels + delta).clamp(row.minScrollExtent, row.maxScrollExtent) != row.pixels) return;
    final parent = Scrollable.maybeOf(context, axis: Axis.vertical)?.position;
    if (parent == null ||
        (parent.pixels + delta).clamp(parent.minScrollExtent, parent.maxScrollExtent) == parent.pixels) {
      return;
    }
    // 行内可以移动时交给 Flutter；只有行边界的 Shift+滚轮才转交纵向页面。
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      InputMode.markPointer();
      parent.pointerScroll((e as PointerScrollEvent).scrollDelta.dy);
    });
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
            child: Listener(
              onPointerSignal: widget.forwardShiftWheelAtEdge && PlatformProfile.isDesktop ? _forwardEdgeScroll : null,
              child: ListView.separated(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                // 屏幕外提前构建的范围：电视 800 像素（左右各多两三张卡），电脑 1600。
                // 电视上每行少建一半屏外卡片，首页十来行加起来少解码几十张海报
                scrollCacheExtent: ScrollCacheExtent.pixels(PlatformProfile.isTv ? 800 : 1600),
                padding: EdgeInsets.fromLTRB(widget.leading, FocusRow.focusBleed, VSpace.safeH, FocusRow.focusBleed),
                itemCount: widget.itemCount,
                findItemIndexCallback: widget.itemKeys == null
                    ? null
                    : (key) {
                        final i = widget.itemKeys!.indexOf((key as ValueKey<Object>).value);
                        return i < 0 ? null : i;
                      },
                separatorBuilder: (_, _) => SizedBox(width: widget.gap),
                itemBuilder: (context, index) => SizedBox(
                  key: widget.itemKeys == null ? null : ValueKey(widget.itemKeys![index]),
                  width: widget.itemExtent,
                  child: widget.itemBuilder(context, index, nodeAt(index)),
                ),
              ),
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
