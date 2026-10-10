import 'package:flutter/widgets.dart';

/// 把 1920 宽的设计画布等比缩放到实际窗口 / 屏幕。
///
/// 子树里看到的 `MediaQuery.size.width` 恒为 [designWidth]，高度按窗口比例换算，
/// 因此所有页面都可以直接使用效果图上的像素值。
class DesignScale extends StatelessWidget {
  const DesignScale({super.key, required this.child, this.designWidth = 1920});

  final double designWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || constraints.maxWidth == 0) {
          return child;
        }
        final scale = constraints.maxWidth / designWidth;
        final logical = Size(designWidth, constraints.maxHeight / scale);
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
                    devicePixelRatio: mq.devicePixelRatio * scale,
                    padding: mq.padding / scale,
                    viewPadding: mq.viewPadding / scale,
                    viewInsets: mq.viewInsets / scale,
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
