import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/platform_profile.dart';
import '../../app/theme.dart';

/// 磨砂玻璃的性能档位（docs/06-ui-design.md §2.1）。
enum GlassQuality {
  /// 全部实时模糊
  high,

  /// 小面积（面板 / OSD / 导航栏）实时模糊，大背景用预模糊
  medium,

  /// 不做实时模糊，用更不透明的深色面板代替
  low,
}

class GlassQualityNotifier extends Notifier<GlassQuality> {
  @override
  // 电视盒子 GPU 弱：实时模糊（BackdropFilter）每帧都要重新模糊整块背景，是首页卡顿的主要来源，
  // 电视默认不做实时模糊，用更不透明的深色面板；Windows 保持磨砂效果
  GlassQuality build() => PlatformProfile.isTv ? GlassQuality.low : GlassQuality.medium;

  void set(GlassQuality q) => state = q;
}

final glassQualityProvider = NotifierProvider<GlassQualityNotifier, GlassQuality>(GlassQualityNotifier.new);

/// 磨砂玻璃容器：模糊 + 半透明填充 + 1px 描边 + 顶部高光。
class Glass extends ConsumerWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = VRadius.panel,
    this.blur = 28,
    this.fill = VColors.glassFill,
    this.border = VColors.glassBorder,
    this.padding,
    this.width,
    this.height,
  });

  final Widget child;
  final double radius;
  final double blur;
  final Color fill;
  final Color border;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quality = ref.watch(glassQualityProvider);
    final borderRadius = BorderRadius.circular(radius);
    final lowFill = Color.alphaBlend(fill, const Color(0xD914161E));

    final decorated = Container(
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: quality == GlassQuality.low ? lowFill : fill,
        borderRadius: borderRadius,
        border: Border.all(color: border),
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.center,
          colors: [VColors.glassHighlight, Color(0x00FFFFFF)],
          stops: [0, 0.04],
        ),
      ),
      child: child,
    );

    if (quality == GlassQuality.low) {
      return decorated;
    }
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.compose(
          outer: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur, tileMode: TileMode.clamp),
          inner: const ColorFilter.matrix(_saturate160),
        ),
        child: decorated,
      ),
    );
  }
}

/// saturate(160%) 的颜色矩阵，让玻璃下的颜色更通透。
const List<double> _saturate160 = <double>[
  1.4722, -0.4290, -0.0432, 0, 0, //
  -0.1278, 1.1710, -0.0432, 0, 0, //
  -0.1278, -0.4290, 1.5568, 0, 0, //
  0, 0, 0, 1, 0, //
];
