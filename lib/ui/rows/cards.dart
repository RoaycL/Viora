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
    this.tagIcon,
    this.titleSuffix,
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

  /// 标题后的灰色附加信息（如"第 1 季 · 195 集"）
  final String? titleSuffix;

  /// 角标前的小图标（继续观看用服务器图标标注来源）
  final IconData? tagIcon;
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
          semanticLabel: title,
          semanticValue: [?titleSuffix, ?subtitle, ?tag, ?caption].join('，'),
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
                        radius: VRadius.xs,
                        blur: 12,
                        fill: const Color(0x59000000),
                        border: const Color(0x00000000),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (tagIcon != null) ...[
                              Icon(tagIcon, size: 16, color: const Color(0xE6FFFFFF)),
                              const SizedBox(width: 6),
                            ],
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 260),
                              child: Text(
                                tag!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 16, color: Color(0xE6FFFFFF)),
                              ),
                            ),
                          ],
                        ),
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
        ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (titleSuffix == null)
                Text(title, style: _titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis)
              else
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: title),
                      TextSpan(
                        text: '  $titleSuffix',
                        style: _subStyle.copyWith(fontSize: _titleStyle.fontSize),
                      ),
                    ],
                  ),
                  style: _titleStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(subtitle!, style: _subStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ],
          ),
        ),
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
    // 无资源时压暗（用遮罩而不是透明度，避免背景图透过海报）；聚焦时恢复。
    final dimmed = resources == 0 ? 0.55 : 1.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        VFocusable(
          focusNode: node,
          semanticLabel: title,
          semanticValue: [?subtitle, if (resources != null) resources == 0 ? '无资源' : '$resources 个资源'].join('，'),
          onActivate: onActivate,
          onMenu: onMenu,
          onFocusChange: onFocusChange,
          builder: (context, focused) => ClipRRect(
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
                  IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: focused || resources != 0 ? 0 : 0.5,
                      duration: VMotion.duration(context, VMotion.focus),
                      child: const ColoredBox(color: VColors.background),
                    ),
                  ),
                  if (resources != null) Positioned(left: 12, top: 12, child: _ResourceBadge(resources!)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Opacity(
          opacity: dimmed,
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: _titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitle != null) ...[const SizedBox(height: 4), Text(subtitle!, style: _subStyle, maxLines: 1)],
              ],
            ),
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
        color: has ? const Color(0xCC0E3A22) : const Color(0xA6000000),
        border: has ? Border.all(color: const Color(0x665BE38A)) : null,
        borderRadius: BorderRadius.circular(VRadius.xs),
      ),
      child: Text(
        has ? '$count 个资源' : '无资源',
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: has ? const Color(0xFFB4F7CB) : const Color(0xBFFFFFFF),
        ),
      ),
    );
  }
}

/// 人物圆形卡 160。
class PersonCard extends StatelessWidget {
  const PersonCard({
    super.key,
    required this.node,
    required this.art,
    required this.name,
    this.image,
    this.role,
    this.onActivate,
  });

  static const size = 160.0;
  static const height = size + 12 + 56;

  final FocusNode node;
  final ArtSpec art;
  final String name;
  final Widget? image;
  final String? role;
  final VoidCallback? onActivate;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        VFocusable(
          focusNode: node,
          semanticLabel: name,
          semanticValue: role,
          radius: size / 2,
          onActivate: onActivate,
          builder: (context, focused) => ClipOval(
            child: SizedBox(width: size, height: size, child: image ?? ArtView(art)),
          ),
        ),
        const SizedBox(height: 12),
        ExcludeSemantics(
          child: SizedBox(
            width: size + 20,
            child: Text(
              name,
              style: const TextStyle(fontSize: 20),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        ),
        if (role != null)
          ExcludeSemantics(
            child: SizedBox(
              width: size + 20,
              child: Text(
                role!,
                style: const TextStyle(fontSize: 16, color: VColors.textTertiary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  }
}

/// 播出平台 / 电影公司 Logo 卡 300×170（没有 Logo 时显示文字）。
class BrandCard extends StatelessWidget {
  const BrandCard({
    super.key,
    required this.node,
    required this.art,
    required this.name,
    this.logo,
    this.backgroundColor,
    this.onActivate,
  });

  static const width = 300.0;
  static const height = 170.0;

  /// 品牌 Logo 卡统一的浅色底（原色 Logo 在上面都清楚）
  static const logoBackground = Color(0xFFF2F2F5);

  final FocusNode node;
  final ArtSpec art;
  final String name;
  final Widget? logo;
  final Color? backgroundColor;
  final VoidCallback? onActivate;

  @override
  Widget build(BuildContext context) {
    return VFocusable(
      focusNode: node,
      semanticLabel: name,
      radius: VRadius.card,
      onActivate: onActivate,
      builder: (context, focused) => ClipRRect(
        borderRadius: BorderRadius.circular(VRadius.card),
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (backgroundColor case final color?)
                ColoredBox(color: color)
              else
                ArtView(art, lightCenter: const Alignment(0, 0.2)),
              if (logo != null)
                Padding(padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 48), child: logo)
              else
                Center(
                  child: Text(
                    name,
                    style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w900, letterSpacing: 1),
                  ),
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
