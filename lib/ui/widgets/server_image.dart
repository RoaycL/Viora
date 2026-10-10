import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/media/media_models.dart';
import '../../data/media/server_registry.dart';
import 'art.dart';
import 'image_sizing.dart';

/// 媒体服务器上的图片：地址经过线路 / 代理改写，请求带 UA。
/// 没有图或加载失败时显示占位渐变。
class ServerImage extends ConsumerWidget {
  const ServerImage({
    super.key,
    required this.serverId,
    required this.image,
    this.width = 220,
    this.fit = BoxFit.cover,
    this.fallbackSeed = '',
    this.alignment = Alignment.center,
    this.transparentFallback = false,
  });

  final String serverId;
  final ImageRef? image;

  /// 图片在设计稿上的显示宽度（实际请求 / 解码尺寸按设备分辨率换算）
  final double width;
  final BoxFit fit;
  final String fallbackSeed;
  final Alignment alignment;

  /// Logo 等透明图：加载中 / 失败时不显示占位渐变
  final bool transparentFallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(serverClientProvider(serverId));
    final Widget fallback = transparentFallback ? const SizedBox.shrink() : ArtView(placeholderArt(fallbackSeed));
    if (client == null || image == null) return fallback;
    final px = ImageSizing.physicalWidth(context, width);
    final req = client.image(image!, maxWidth: px);
    return Image.network(
      req.url.toString(),
      headers: req.headers,
      // 按显示尺寸解码，大图不会占满内存（电视盒子尤其重要）
      cacheWidth: px,
      fit: fit,
      alignment: alignment,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      frameBuilder: (context, child, frame, sync) => sync
          ? child
          : Stack(
              fit: StackFit.expand,
              children: [
                fallback,
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

const _palette = <ArtSpec>[
  ArtSpec(Color(0xFF2E5C8A), Color(0xFF0C1626), Color(0xFFC9D6FF)),
  ArtSpec(Color(0xFF7A4A2E), Color(0xFF1E120A), Color(0xFFFFD9A8)),
  ArtSpec(Color(0xFF5A3C8A), Color(0xFF120C22), Color(0xFFF2C4FF)),
  ArtSpec(Color(0xFF2E6A5C), Color(0xFF0A1A16), Color(0xFF9FE3C8)),
  ArtSpec(Color(0xFF6A2E4A), Color(0xFF1A0A12), Color(0xFFFF9FC4)),
  ArtSpec(Color(0xFF3A4A4A), Color(0xFF0E1414), Color(0xFFA8C8C0)),
];

/// 按字符串稳定地挑一个占位渐变
ArtSpec placeholderArt(String seed) => _palette[seed.codeUnits.fold<int>(0, (a, b) => a + b) % _palette.length];
