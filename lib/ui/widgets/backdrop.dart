import 'package:flutter/widgets.dart';

import '../../app/theme.dart';
import 'art.dart';

/// 全屏动态背景：背景图交叉淡入 + 左侧与底部压暗（效果图同款）。
class PageBackdrop extends StatelessWidget {
  const PageBackdrop({
    super.key,
    required this.art,
    this.image,
    this.imageKey,
    this.dimLeft = true,
    this.fadeBottomFrom = 0.4,
  });

  final ArtSpec art;

  /// 真实背景图（盖在 [art] 上，加载完成前显示 [art]）；[imageKey] 变化时交叉淡入
  final Widget? image;
  final Object? imageKey;
  final bool dimLeft;

  /// 从屏幕高度的哪个比例开始向底部渐隐到背景色
  final double fadeBottomFrom;

  @override
  Widget build(BuildContext context) {
    // 单独一层：卡片焦点动画、轮播文字变化时不连带重绘整屏背景图（电视 GPU 弱，影响明显）
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedSwitcher(
            duration: VMotion.backdrop,
            child: image == null
                ? ArtView(art, key: ValueKey(art), lightCenter: const Alignment(0.5, -0.4))
                : Stack(
                    key: ValueKey(imageKey ?? art),
                    fit: StackFit.expand,
                    children: [
                      ArtView(art, lightCenter: const Alignment(0.5, -0.4)),
                      image!,
                    ],
                  ),
          ),
          if (dimLeft)
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  // 左侧压暗减轻：背景图延伸到导航栏下方，同时保证 Hero 文字可读
                  stops: [0, 0.32, 0.65, 1],
                  colors: [Color(0x9907080B), Color(0x8007080B), Color(0x1F07080B), Color(0x0007080B)],
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
      ),
    );
  }
}
