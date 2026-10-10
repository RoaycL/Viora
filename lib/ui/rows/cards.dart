import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../focus/focusable.dart';
import '../glass/glass.dart';
import '../widgets/art.dart';

const _titleStyle = TextStyle(fontSize: 22, color: Color(0xE0FFFFFF));
const _subStyle = TextStyle(fontSize: 18, color: VColors.textTertiary);

/// 继续观看等横版卡片 400×225（带服务器标签、剩余时间与进度条）。
class LandscapeCard extends StatelessWidget {
  const LandscapeCard({
    super.key,
    required this.node,
    required this.art,
    required this.title,
    this.image,
    this.subtitle,
    this.tag,
    this.caption,
    this.progress,
    this.onActivate,
    this.onMenu,
  });

  static const width = 400.0;
  static const imageHeight = 225.0;
  static const height = imageHeight + 12 + 64;

  final FocusNode node;
  final ArtSpec art;

  /// 真实图片；为空时显示 [art] 渐变
  final Widget? image;
  final String title;
  final String? subtitle;
  final String? tag;
  final String? caption;
  final double? progress;
  final VoidCallback? onActivate;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        VFocusable(
          focusNode: node,
          onActivate: onActivate,
          onMenu: onMenu,
          builder: (context, focused) => ClipRRect(
            borderRadius: BorderRadius.circular(VRadius.card),
            child: SizedBox(
              width: width,
              height: imageHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  image ?? ArtView(art),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: [0.5, 1],
                        colors: [Color(0x00000000), Color(0x99000000)],
                      ),
                    ),
                  ),
                  if (tag != null)
                    Positioned(
                      left: 16,
                      top: 14,
                      child: Glass(
                        radius: 8,
                        blur: 12,
                        fill: const Color(0x59000000),
                        border: const Color(0x00000000),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        child: Text(tag!, style: const TextStyle(fontSize: 16, color: Color(0xE6FFFFFF))),
                      ),
                    ),
                  if (caption != null)
                    Positioned(
                      left: 16,
                      bottom: 24,
                      child: Text(caption!, style: const TextStyle(fontSize: 18, color: Color(0xE0FFFFFF))),
                    ),
                  if (progress != null) Positioned(left: 16, right: 16, bottom: 12, child: ProgressLine(progress!)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(title, style: _titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle!, style: _subStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ],
    );
  }
}

/// 竖版海报 220×330。无资源时半透明并显示"无资源"。
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.node,
    required this.art,
    required this.title,
    this.image,
    this.subtitle,
    this.resources,
    this.onActivate,
    this.onMenu,
    this.onFocusChange,
  });

  static const width = 220.0;
  static const imageHeight = 330.0;
  static const height = imageHeight + 12 + 64;

  final FocusNode node;
  final ArtSpec art;

  /// 真实图片；为空时显示 [art] 渐变
  final Widget? image;
  final String title;
  final String? subtitle;

  /// null = 不显示资源角标
  final int? resources;
  final VoidCallback? onActivate;
  final VoidCallback? onMenu;
  final ValueChanged<bool>? onFocusChange;

  @override
  Widget build(BuildContext context) {
    // 无资源时半透明；聚焦时恢复不透明，保证焦点框清晰。
    final dimmed = resources == 0 ? 0.55 : 1.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        VFocusable(
          focusNode: node,
          onActivate: onActivate,
          onMenu: onMenu,
          onFocusChange: onFocusChange,
          builder: (context, focused) => AnimatedOpacity(
            opacity: focused ? 1 : dimmed,
            duration: VMotion.focus,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(VRadius.card),
              child: SizedBox(
                width: width,
                height: imageHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    image ?? ArtView(art),
                    if (image == null)
                      Positioned(
                        left: 14,
                        right: 14,
                        bottom: 14,
                        child: Text(
                          title,
                          maxLines: 2,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1,
                            shadows: [Shadow(color: Color(0x99000000), blurRadius: 12)],
                          ),
                        ),
                      ),
                    if (resources != null) Positioned(left: 12, top: 12, child: _ResourceBadge(resources!)),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Opacity(
          opacity: dimmed,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: _titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (subtitle != null) ...[const SizedBox(height: 4), Text(subtitle!, style: _subStyle, maxLines: 1)],
            ],
          ),
        ),
      ],
    );
  }
}

class _ResourceBadge extends StatelessWidget {
  const _ResourceBadge(this.count);

  final int count;

  @override
  Widget build(BuildContext context) {
    final has = count > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: has ? const Color(0x385BE38A) : const Color(0x73000000),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        has ? '$count 个资源' : '无资源',
        style: TextStyle(fontSize: 15, color: has ? const Color(0xFF9AF2B8) : const Color(0xBFFFFFFF)),
      ),
    );
  }
}

/// 人物圆形卡 160。
class PersonCard extends StatelessWidget {
  const PersonCard({super.key, required this.node, required this.art, required this.name, this.role, this.onActivate});

  static const size = 160.0;
  static const height = size + 12 + 56;

  final FocusNode node;
  final ArtSpec art;
  final String name;
  final String? role;
  final VoidCallback? onActivate;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        VFocusable(
          focusNode: node,
          radius: size / 2,
          onActivate: onActivate,
          builder: (context, focused) => ClipOval(
            child: SizedBox(width: size, height: size, child: ArtView(art)),
          ),
        ),
        const SizedBox(height: 12),
        Text(name, style: const TextStyle(fontSize: 20), maxLines: 1),
        if (role != null) Text(role!, style: const TextStyle(fontSize: 16, color: VColors.textTertiary)),
      ],
    );
  }
}

/// 播出平台 / 电影公司 Logo 卡 300×170（Logo 暂用文字代替）。
class BrandCard extends StatelessWidget {
  const BrandCard({super.key, required this.node, required this.art, required this.name, this.onActivate});

  static const width = 300.0;
  static const height = 170.0;

  final FocusNode node;
  final ArtSpec art;
  final String name;
  final VoidCallback? onActivate;

  @override
  Widget build(BuildContext context) {
    return VFocusable(
      focusNode: node,
      radius: 20,
      onActivate: onActivate,
      builder: (context, focused) => ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ArtView(art, lightCenter: const Alignment(0, 0.2)),
              Center(
                child: Text(name, style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w900, letterSpacing: 1)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProgressLine extends StatelessWidget {
  const ProgressLine(this.value, {super.key, this.height = 4});

  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0x40FFFFFF)),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: value.clamp(0, 1),
              child: const ColoredBox(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
