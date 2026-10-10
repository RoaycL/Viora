import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/tmdb/tmdb_client.dart';
import 'art.dart';
import 'server_image.dart';

/// TMDB 图片（image.tmdb.org，可走反向代理）。没有图或加载失败时显示占位渐变。
class TmdbImage extends ConsumerWidget {
  const TmdbImage({
    super.key,
    required this.path,
    this.size = 'w500',
    this.fit = BoxFit.cover,
    this.fallbackSeed = '',
    this.alignment = Alignment.center,
    this.transparentFallback = false,
    this.color,
    this.fallback,
  });

  final String? path;
  final String size;
  final BoxFit fit;
  final String fallbackSeed;
  final Alignment alignment;
  final bool transparentFallback;

  /// 单色化（播出平台 Logo 统一成白色）
  final Color? color;

  /// 自定义的加载中 / 失败占位（例如 Logo 加载不到时显示文字标题）
  final Widget? fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(tmdbClientProvider);
    final Widget fallback =
        this.fallback ?? (transparentFallback ? const SizedBox.shrink() : ArtView(placeholderArt(fallbackSeed)));
    if (client == null || path == null || path!.isEmpty) return fallback;
    return Image.network(
      client.image(path!, size: size),
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
      errorBuilder: (_, _, _) => fallback,
    );
  }
}
