import 'package:flutter/widgets.dart';

/// 按设备实际分辨率决定图片尺寸（docs/06-ui-design.md §2.2）：
/// 设计稿上的宽度 × 每个设计像素对应的物理像素数（[DesignScale] 写进 MediaQuery.devicePixelRatio）。
/// 4K 电视请求更大的图保证清晰，小窗口请求小图省流量和内存。
abstract final class ImageSizing {
  /// 固定的几档尺寸（向上取最近一档）：窗口大小变化时不会反复换图；
  /// 媒体服务器（Emby / Jellyfin）每遇到一个新尺寸都要在 NAS 上现场缩放并缓存，档位少可以大幅减少 CPU 负载。
  static const tiers = [240, 360, 480, 720, 1080, 1440, 1920, 2560, 3840];

  static int physicalWidth(BuildContext context, double designWidth) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final px = (designWidth * dpr).ceil();
    return tiers.firstWhere((t) => t >= px, orElse: () => tiers.last);
  }
}
