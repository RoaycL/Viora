import 'package:flutter/foundation.dart';

/// 字幕边框（播放页「字幕 → 字幕样式」）
enum SubtitleEdge {
  /// 默认：mpv 白字黑描边 + 柔和阴影；ExoPlayer 跟随系统的字幕样式（没开系统字幕时是黑色底框）
  auto,

  /// 黑色描边
  outline,

  /// 阴影（没有描边，画面干净一些）
  shadow,

  /// 半透明黑色底框（花哨画面上最清楚）
  box,
}

/// 字幕外观：颜色、边框、描边粗细。对 ASS 等自带样式的字幕，ExoPlayer 仍按字幕自己的样式显示
@immutable
class SubtitleLook {
  const SubtitleLook({this.color = white, this.edge = SubtitleEdge.auto, this.outline = 1.0});

  static const white = 0xFFFFFFFF;

  /// 文字颜色（ARGB）
  final int color;
  final SubtitleEdge edge;

  /// 描边 / 阴影粗细倍数（1 = 标准）
  final double outline;

  static const colors = [(white, '白'), (0xFFFFE15A, '黄'), (0xFFD9D9D9, '浅灰')];
  static const edges = [
    (SubtitleEdge.auto, '默认'),
    (SubtitleEdge.outline, '描边'),
    (SubtitleEdge.shadow, '阴影'),
    (SubtitleEdge.box, '背景框'),
  ];
  static const outlines = [(0.6, '细'), (1.0, '标准'), (1.6, '粗'), (2.2, '特粗')];

  bool get isDefault => color == white && edge == SubtitleEdge.auto && outline == 1.0;

  Map<String, Object> toJson() => {'color': color, 'edge': edge.name, 'outline': outline};

  @override
  bool operator ==(Object other) =>
      other is SubtitleLook && other.color == color && other.edge == edge && other.outline == outline;

  @override
  int get hashCode => Object.hash(color, edge, outline);
}
