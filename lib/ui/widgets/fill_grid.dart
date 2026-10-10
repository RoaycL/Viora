import 'package:flutter/widgets.dart';

/// 铺满宽度的网格：按可用宽度算出列数，卡片按 [itemWidth] 的设计尺寸等比缩放到刚好填满一行，
/// 窗口变宽时不会在右侧留下大片空白。
class FillGrid extends StatelessWidget {
  const FillGrid({
    super.key,
    required this.itemWidth,
    required this.children,
    this.spacing = 24,
    this.runSpacing = 32,
    this.maxScale = 1.3,
  });

  /// 卡片的设计宽度（列数按它估算）
  final double itemWidth;
  final double spacing;
  final double runSpacing;

  /// 最多放大到设计尺寸的多少倍（超过就多分一列）
  final double maxScale;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        var columns = ((w + spacing) / (itemWidth + spacing)).floor().clamp(1, 99);
        double cell() => (w - spacing * (columns - 1)) / columns;
        while (cell() > itemWidth * maxScale) {
          columns++;
        }
        final scale = (cell() / itemWidth).clamp(0.5, maxScale);
        return Wrap(
          spacing: spacing,
          runSpacing: runSpacing,
          children: [
            for (final c in children)
              SizedBox(
                width: itemWidth * scale,
                child: FittedBox(
                  fit: BoxFit.fitWidth,
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: itemWidth, child: c),
                ),
              ),
          ],
        );
      },
    );
  }
}
