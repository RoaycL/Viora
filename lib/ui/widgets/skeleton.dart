import 'package:flutter/material.dart';

import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../rows/cards.dart';
import 'fill_grid.dart';

/// 加载中的占位（收藏、观看记录、媒体库等页面）：和真实卡片同样的尺寸与排布，内容到了直接替换，页面不跳。
/// 占位不可聚焦：加载期间焦点留在导航上，可以继续切换页面。
/// 电视上静止（弱 GPU 上省掉每帧重绘），Windows 上轻微呼吸。

Widget skeletonBlock(double w, double h, {double radius = 10}) => Container(
  width: w,
  height: h,
  decoration: BoxDecoration(color: const Color(0x1FFFFFFF), borderRadius: BorderRadius.circular(radius)),
);

/// 一张卡片的占位：图片 + 一行标题
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key, this.landscape = false});

  final bool landscape;

  double get width => landscape ? LandscapeCard.width : PosterCard.width;

  @override
  Widget build(BuildContext context) {
    final w = width;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        skeletonBlock(w, landscape ? LandscapeCard.imageHeight : PosterCard.imageHeight, radius: VRadius.card),
        const SizedBox(height: 14),
        skeletonBlock(w * 0.75, 20, radius: 6),
      ],
    );
  }
}

/// 网格页的占位（sliver）：铺满两三行，排布与 [SliverFillGrid] 一致
class SliverSkeletonGrid extends StatelessWidget {
  const SliverSkeletonGrid({super.key, this.landscape = false, this.count = 18});

  final bool landscape;
  final int count;

  @override
  Widget build(BuildContext context) {
    return SliverFillGrid(
      itemWidth: landscape ? LandscapeCard.width : PosterCard.width,
      itemCount: count,
      itemBuilder: (context, i) => SkeletonShimmer(child: SkeletonCard(landscape: landscape)),
    );
  }
}

/// 一行卡片的占位（带行标题）
class SkeletonRow extends StatelessWidget {
  const SkeletonRow({super.key, required this.title, this.landscape = false, this.itemWidth, this.imageHeight});

  final String title;
  final bool landscape;

  /// 自定义卡片尺寸（如媒体库卡片 400×225）
  final double? itemWidth;
  final double? imageHeight;

  @override
  Widget build(BuildContext context) {
    final w = itemWidth ?? (landscape ? LandscapeCard.width : PosterCard.width);
    final h = imageHeight ?? (landscape ? LandscapeCard.imageHeight : PosterCard.imageHeight);
    final count = ((MediaQuery.sizeOf(context).width - VSpace.contentLeft) / (w + VSpace.rowGap)).ceil() + 1;
    return Padding(
      padding: EdgeInsets.only(left: VSpace.contentLeft, top: 28, bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: VText.rowTitle.copyWith(color: const Color(0xEBFFFFFF))),
          const SizedBox(height: 20),
          ClipRect(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: SkeletonShimmer(
                child: Row(
                  children: [
                    for (var i = 0; i < count; i++) ...[
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          skeletonBlock(w, h, radius: VRadius.card),
                          const SizedBox(height: 14),
                          skeletonBlock(w * 0.75, 20, radius: 6),
                        ],
                      ),
                      const SizedBox(width: VSpace.rowGap),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 占位的呼吸动画：电视、系统减少动画时静止
class SkeletonShimmer extends StatefulWidget {
  const SkeletonShimmer({super.key, required this.child});

  final Widget child;

  @override
  State<SkeletonShimmer> createState() => _SkeletonShimmerState();
}

class _SkeletonShimmerState extends State<SkeletonShimmer> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (PlatformProfile.isTv || VMotion.reduced(context)) {
      _c.stop();
      _c.value = 0.6;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween(begin: 0.45, end: 1.0).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
    child: widget.child,
  );
}
