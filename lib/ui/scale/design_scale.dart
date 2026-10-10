import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 把 1920 宽的设计画布等比缩放到实际窗口 / 屏幕。
///
/// 子树里看到的 `MediaQuery.size.width` 恒为 [designWidth]，高度按窗口比例换算，
/// 因此所有页面都可以直接使用效果图上的像素值。界面按设备实际分辨率绘制（4K 下文字和图标依然清晰），
/// `MediaQuery.devicePixelRatio` 为每个设计像素对应的物理像素数，图片按它选尺寸。
///
/// 拖动窗口边框（Windows）时：连续调整大小期间冻结子树的布局，只把上一帧的界面快照按新尺寸缩放显示；
/// 停止拖动 [settleDelay] 后再按新尺寸重新布局一次。这样拖动时不用每帧重建、重排、重绘整个界面（以及毛玻璃模糊）。
/// 一次性的尺寸变化（最大化、还原、全屏）直接重新布局，不冻结。
class DesignScale extends StatefulWidget {
  const DesignScale({super.key, required this.child, this.designWidth = 1920});

  final double designWidth;
  final Widget child;

  /// 两次尺寸变化间隔小于这个值视为"正在拖动"
  static const dragInterval = Duration(milliseconds: 150);

  /// 停止拖动多久后重新布局
  static const settleDelay = Duration(milliseconds: 160);

  /// 播放页打开时不用快照（视频画面要实时更新）
  static final snapshotAllowed = ValueNotifier(true);

  @override
  State<DesignScale> createState() => _DesignScaleState();
}

class _DesignScaleState extends State<DesignScale> {
  final _snapshot = SnapshotController();
  Size? _lastWindow;
  DateTime _lastChange = DateTime.fromMillisecondsSinceEpoch(0);

  /// 拖动期间冻结的画布尺寸与像素比
  Size? _frozenLogical;
  double? _frozenScale;

  /// 最近一次实际使用的画布尺寸与缩放
  Size? _appliedLogical;
  double? _appliedScale;
  Timer? _settle;

  @override
  void dispose() {
    _settle?.cancel();
    _snapshot.dispose();
    super.dispose();
  }

  void _onWindowSize(Size window) {
    final last = _lastWindow;
    _lastWindow = window;
    if (last == null || last == window) return;
    final now = DateTime.now();
    final dragging = now.difference(_lastChange) < DesignScale.dragInterval;
    _lastChange = now;
    if (dragging && _frozenLogical == null && _appliedLogical != null) {
      _frozenLogical = _appliedLogical;
      _frozenScale = _appliedScale;
      _snapshot.allowSnapshotting = DesignScale.snapshotAllowed.value;
    }
    if (_frozenLogical != null) {
      _settle?.cancel();
      _settle = Timer(DesignScale.settleDelay, _unfreeze);
    }
  }

  void _unfreeze() {
    if (!mounted) return;
    _snapshot.allowSnapshotting = false;
    setState(() {
      _frozenLogical = null;
      _frozenScale = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || constraints.maxWidth == 0) {
          return widget.child;
        }
        _onWindowSize(constraints.biggest);
        final scale = constraints.maxWidth / widget.designWidth;
        final live = Size(widget.designWidth, constraints.maxHeight / scale);
        // 拖动中：画布尺寸与像素比保持不变（子树不重建、不重排），只改变外层缩放
        final logical = _frozenLogical ?? live;
        final dprScale = _frozenScale ?? scale;
        _appliedLogical = logical;
        _appliedScale = dprScale;
        final mq = MediaQuery.of(context);
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 0,
            minHeight: 0,
            maxWidth: double.infinity,
            maxHeight: double.infinity,
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: logical.width,
                height: logical.height,
                child: MediaQuery(
                  data: mq.copyWith(
                    size: logical,
                    devicePixelRatio: mq.devicePixelRatio * dprScale,
                    padding: mq.padding / dprScale,
                    viewPadding: mq.viewPadding / dprScale,
                    viewInsets: mq.viewInsets / dprScale,
                  ),
                  child: kIsWeb
                      ? widget.child
                      : SnapshotWidget(controller: _snapshot, mode: SnapshotMode.permissive, child: widget.child),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
