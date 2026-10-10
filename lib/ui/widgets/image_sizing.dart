import 'package:flutter/widgets.dart';

/// 按设备实际分辨率决定图片尺寸（docs/06-ui-design.md §2.2）：
/// 设计稿上的宽度 × 每个设计像素对应的物理像素数（[DesignScale] 写进 MediaQuery.devicePixelRatio）。
/// 4K 电视请求更大的图保证清晰，小窗口请求小图省流量和内存。
abstract final class ImageSizing {
  /// 物理像素按 128 向上取整，窗口大小微调时不会反复换图
  static const _bucket = 128;

  static int physicalWidth(BuildContext context, double designWidth) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final px = (designWidth * dpr).ceil();
    return ((px + _bucket - 1) ~/ _bucket * _bucket).clamp(_bucket, 4096);
  }
}
