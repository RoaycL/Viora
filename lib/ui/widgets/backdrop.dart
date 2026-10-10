import 'package:flutter/widgets.dart';

import '../../app/theme.dart';
import 'art.dart';

/// 全屏动态背景：背景图交叉淡入 + 左侧与底部压暗（效果图同款）。
class PageBackdrop extends StatelessWidget {
  const PageBackdrop({super.key, required this.art, this.dimLeft = true, this.fadeBottomFrom = 0.4});

  final ArtSpec art;
  final bool dimLeft;

  /// 从屏幕高度的哪个比例开始向底部渐隐到背景色
  final double fadeBottomFrom;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedSwitcher(
          duration: VMotion.backdrop,
          child: ArtView(art, key: ValueKey(art), lightCenter: const Alignment(0.5, -0.4)),
        ),
        if (dimLeft)
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                stops: [0, 0.3, 0.62, 1],
                colors: [Color(0xF507080B), Color(0xD107080B), Color(0x3307080B), Color(0x0007080B)],
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [fadeBottomFrom, fadeBottomFrom + 0.26, fadeBottomFrom + 0.42],
              colors: const [Color(0x0007080B), Color(0xD907080B), VColors.background],
            ),
          ),
        ),
      ],
    );
  }
}
