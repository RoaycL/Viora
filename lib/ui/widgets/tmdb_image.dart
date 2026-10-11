import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/tmdb/tmdb_client.dart';
import 'art.dart';
import 'cached_image.dart';
import 'image_sizing.dart';
import 'server_image.dart';

/// TMDB 图片的种类（各自可用的尺寸不同）
enum TmdbImageKind {
  poster([92, 154, 185, 342, 500, 780]),
  backdrop([300, 780, 1280]),
  profile([45, 185]),
  logo([45, 92, 154, 185, 300, 500]),

  /// 剧集单集剧照
  still([92, 185, 300]);

  const TmdbImageKind(this.widths);

  final List<int> widths;

  /// 不小于 [px] 的最小尺寸；都不够时用原图
  String sizeFor(int px) {
    for (final w in widths) {
      if (w >= px) return 'w$w';
    }
    return 'original';
  }
}

/// TMDB 图片（image.tmdb.org，可走反向代理）。没有图或加载失败时显示占位渐变。
/// 尺寸按设备实际分辨率选择：1080P 的海报用 w342，4K 用 w500，全屏背景 4K 用原图。
class TmdbImage extends ConsumerWidget {
  const TmdbImage({
    super.key,
    required this.path,
    this.kind = TmdbImageKind.poster,
    this.width = 220,
    this.fit = BoxFit.cover,
    this.fallbackSeed = '',
    this.alignment = Alignment.center,
    this.transparentFallback = false,
    this.color,
    this.fallback,
    this.errorFallback,
  });

  final String? path;
  final TmdbImageKind kind;

  /// 图片在设计稿上的显示宽度
  final double width;
  final BoxFit fit;
  final String fallbackSeed;
  final Alignment alignment;
  final bool transparentFallback;

  /// 单色化（播出平台 Logo 统一成白色）
  final Color? color;

  /// 自定义的加载中 / 失败占位（例如 Logo 加载不到时显示文字标题）
  final Widget? fallback;

  /// 加载失败时显示（默认同 [fallback]）。Logo 用它：加载中留空，失败才显示文字标题
  final Widget? errorFallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(tmdbClientProvider);
    final Widget fallback =
        this.fallback ?? (transparentFallback ? const SizedBox.shrink() : ArtView(placeholderArt(fallbackSeed)));
    if (client == null || path == null || path!.isEmpty) return fallback;
    final px = ImageSizing.physicalWidth(context, width);
    return Image(
      image: netImage(client.image(path!, size: kind.sizeFor(px)), cacheWidth: px),
      fit: fit,
      alignment: alignment,
      color: color,
      colorBlendMode: color == null ? null : BlendMode.srcIn,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      frameBuilder: (context, child, frame, sync) => sync
          ? child
          : Stack(
              fit: StackFit.expand,
              children: [
                // 透明图（Logo）加载完成后隐藏占位，避免文字标题和 Logo 叠在一起
                AnimatedOpacity(
                  opacity: frame != null && this.fallback != null ? 0 : 1,
                  duration: const Duration(milliseconds: 250),
                  child: fallback,
                ),
                AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: const Duration(milliseconds: 250),
                  child: child,
                ),
              ],
            ),
      errorBuilder: (_, _, _) => errorFallback ?? fallback,
    );
  }
}
