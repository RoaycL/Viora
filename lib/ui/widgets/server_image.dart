import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/media/media_models.dart';
import '../../data/media/server_registry.dart';
import 'art.dart';
import 'cached_image.dart';
import 'image_fade_in.dart';
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
    this.errorFallback,
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

  /// 加载失败时显示（如服务器异常时改用 TMDB 的图）；为空时同加载中的占位
  final Widget? errorFallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(serverClientProvider(serverId));
    final Widget fallback = transparentFallback ? const SizedBox.shrink() : ArtView(placeholderArt(fallbackSeed));
    if (client == null || image == null) return fallback;
    final px = ImageSizing.physicalWidth(context, width);
    final req = client.image(image!, maxWidth: px);
    // 磁盘缓存 + 按显示尺寸解码（大图不会占满内存，电视盒子尤其重要）
    final provider = netImage(req.url.toString(), headers: req.headers, cacheWidth: px);
    return Image(
      image: provider,
      fit: fit,
      alignment: alignment,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      frameBuilder: (context, child, frame, sync) =>
          sync ? child : ImageFadeIn(loaded: frame != null, placeholder: fallback, child: child),
      errorBuilder: (_, _, _) {
        // 失败的结果会一直留在图片缓存里，之后同一张图再显示也直接是失败（以前要鼠标移上去、
        // 卡片尺寸变了才会重新加载）。清掉它，下次重建时重新请求；顺便让客户端检查登录是否过期
        WidgetsBinding.instance.addPostFrameCallback((_) {
          provider.evict();
          client.onImageFailed();
        });
        return errorFallback ?? fallback;
      },
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
