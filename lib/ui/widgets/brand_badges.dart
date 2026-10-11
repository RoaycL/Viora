import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../data/media/media_models.dart';
import '../../domain/models/external_rating.dart';

/// 官方标识（图形来自 Simple Icons，CC0；商标归各自所有者）：评分来源图标、视频格式标识。

/// 评分来源
enum RatingBrand {
  imdb(null, Color(0xFFF5C518), 'IMDb'),
  tmdb(null, Color(0xFF01B4E4), 'TMDB'),
  trakt('assets/brands/trakt.svg', Color(0xFFED1C24), 'Trakt'),
  rottenTomatoes('assets/brands/rottentomatoes.svg', Color(0xFFFA320A), '烂番茄'),
  metacritic('assets/brands/metacritic.svg', Color(0xFFFFCC34), 'Metacritic'),

  /// 媒体库（Emby / Jellyfin 的社区评分）：没有统一的官方图标，用星标
  library(null, Color(0xFFFFC94D), '媒体库');

  const RatingBrand(this.asset, this.color, this.label);
  final String? asset;
  final Color color;
  final String label;

  static RatingBrand of(RatingSource s) => switch (s) {
    RatingSource.imdb => imdb,
    RatingSource.rottenTomatoes => rottenTomatoes,
    RatingSource.metacritic => metacritic,
    RatingSource.trakt => trakt,
  };
}

/// 评分：官方图标 + 分数（如 IMDb 图标 8.0）。鼠标悬停 / 读屏显示来源全名和票数
class RatingBadge extends StatelessWidget {
  const RatingBadge({super.key, required this.brand, required this.value, this.tooltip, this.size = 24});

  final RatingBrand brand;
  final String value;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = brand.asset;
    final icon = brand == RatingBrand.imdb
        ? _ImdbMark(height: size)
        : brand == RatingBrand.tmdb
        ? _TmdbMark(height: size)
        : asset == null
        ? Icon(Icons.star_rounded, size: size * 1.1, color: brand.color)
        : SvgPicture.asset(
            asset,
            height: size,
            colorFilter: ColorFilter.mode(brand.color, BlendMode.srcIn),
            semanticsLabel: brand.label,
          );
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        SizedBox(width: size * 0.3),
        Text(
          value,
          style: TextStyle(fontSize: size * 0.8, fontWeight: FontWeight.w700, color: Colors.white, height: 1),
        ),
      ],
    );
    return Tooltip(message: tooltip ?? brand.label, child: child);
  }
}

/// 视频格式标识：分辨率（4K / 1080P…）+ 动态范围（Dolby Vision 用官方双 D 标识，HDR10+ / HDR10 / HLG 用描边标识）。
/// SDR 是默认情况，只用灰色小字，不抢眼。
class VideoFormatBadges extends StatelessWidget {
  const VideoFormatBadges({super.key, required this.resolution, required this.range, this.height = 30});

  VideoFormatBadges.of(MediaSourceInfo source, {Key? key, double height = 30})
    : this(key: key, resolution: source.resolutionLabel, range: source.video?.range ?? VideoRange.sdr, height: height);

  final String resolution;
  final VideoRange range;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (resolution != '未知') ...[_Outlined(resolution, height: height), SizedBox(width: height * 0.35)],
        Flexible(child: _range()),
      ],
    );
  }

  Widget _range() => switch (range) {
    VideoRange.dolbyVision => DolbyVisionLogo(height: height),
    VideoRange.hdr10Plus => _Outlined('HDR10+', height: height, color: const Color(0xFFFFD27A)),
    VideoRange.hdr10 => _Outlined('HDR10', height: height, color: const Color(0xFFFFD27A)),
    VideoRange.hlg => _Outlined('HLG', height: height, color: const Color(0xFFFFD27A)),
    VideoRange.sdr => Text(
      'SDR',
      style: TextStyle(fontSize: height * 0.55, fontWeight: FontWeight.w600, color: const Color(0x99FFFFFF)),
    ),
  };
}

/// 描边标识（与常见播放器、片源站的 4K / HDR 标识一致）
class _Outlined extends StatelessWidget {
  const _Outlined(this.text, {required this.height, this.color = Colors.white});

  final String text;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: EdgeInsets.symmetric(horizontal: height * 0.28),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: height / 14),
        borderRadius: BorderRadius.circular(height * 0.18),
      ),
      child: Center(
        widthFactor: 1,
        child: Text(
          text,
          style: TextStyle(
            fontSize: height * 0.58,
            fontWeight: FontWeight.w800,
            color: color,
            height: 1,
            letterSpacing: height * 0.02,
          ),
        ),
      ),
    );
  }
}

/// Dolby Vision 标识：双 D 图形 + DOLBY VISION 字样（DOLBY 粗体、VISION 细体，全大写）
class DolbyVisionLogo extends StatelessWidget {
  const DolbyVisionLogo({super.key, this.height = 30, this.color = Colors.white});

  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: height * 0.56, color: color, height: 1, letterSpacing: height * 0.04);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SvgPicture.asset(
          'assets/brands/dolby.svg',
          height: height * 0.78,
          colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          semanticsLabel: 'Dolby',
        ),
        SizedBox(width: height * 0.25),
        Flexible(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'DOLBY',
                  style: style.copyWith(fontWeight: FontWeight.w800),
                ),
                TextSpan(
                  text: ' VISION',
                  style: style.copyWith(fontWeight: FontWeight.w300),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.clip,
            softWrap: false,
          ),
        ),
      ],
    );
  }
}

/// IMDb 官方样式：黄底圆角块 + 黑色粗体 IMDb
class _ImdbMark extends StatelessWidget {
  const _ImdbMark({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: EdgeInsets.symmetric(horizontal: height * 0.2),
      decoration: BoxDecoration(color: RatingBrand.imdb.color, borderRadius: BorderRadius.circular(height * 0.16)),
      child: Center(
        widthFactor: 1,
        child: Text(
          'IMDb',
          style: TextStyle(
            fontSize: height * 0.62,
            fontWeight: FontWeight.w900,
            color: Colors.black,
            height: 1,
            letterSpacing: -height * 0.02,
          ),
        ),
      ),
    );
  }
}

/// TMDB 官方短标识：渐变色 TMDB 字样 + 右侧圆角长条
class _TmdbMark extends StatelessWidget {
  const _TmdbMark({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (rect) => const LinearGradient(colors: [Color(0xFF90CEA1), Color(0xFF01B4E4)]).createShader(rect),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'TMDB',
            style: TextStyle(fontSize: height * 0.72, fontWeight: FontWeight.w900, color: Colors.white, height: 1),
          ),
          SizedBox(width: height * 0.15),
          Container(
            width: height * 0.9,
            height: height * 0.45,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(height)),
          ),
        ],
      ),
    );
  }
}
