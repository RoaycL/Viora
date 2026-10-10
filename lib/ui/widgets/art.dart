import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 占位"图片"：三色光斑渐变（与效果图一致）。
/// 接入媒体库 / TMDB 后由真实图片替换，接口保持 [ArtView] 不变。
@immutable
class ArtSpec {
  const ArtSpec(this.base, this.deep, this.light, {this.angle = 150});

  final Color base;
  final Color deep;
  final Color light;
  final double angle;

  @override
  bool operator ==(Object other) =>
      other is ArtSpec && other.base == base && other.deep == deep && other.light == light && other.angle == angle;

  @override
  int get hashCode => Object.hash(base, deep, light, angle);
}

class ArtView extends StatelessWidget {
  const ArtView(this.spec, {super.key, this.lightCenter = const Alignment(0.44, -0.4)});

  final ArtSpec spec;
  final Alignment lightCenter;

  @override
  Widget build(BuildContext context) {
    // CSS linear-gradient 角度：0° 指向上方，顺时针。
    final rad = spec.angle * math.pi / 180;
    final dir = Alignment(math.sin(rad), -math.cos(rad));
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: -dir, end: dir, colors: [spec.base, spec.deep]),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.64, 0.7),
              radius: 0.75,
              colors: [spec.base, spec.base.withValues(alpha: 0)],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: lightCenter,
              radius: 0.72,
              colors: [spec.light, spec.light.withValues(alpha: 0)],
            ),
          ),
        ),
      ],
    );
  }
}
