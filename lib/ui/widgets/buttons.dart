import 'package:flutter/material.dart';

import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../focus/focusable.dart';
import '../glass/glass.dart';

const _darkInk = Color(0xFF0B0C10);

/// 胶囊按钮：未聚焦为磨砂玻璃，聚焦后变为白底深色字并外发光（Apple TV 式）。
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    this.icon,
    this.subtitle,
    this.focusNode,
    this.autofocus = false,
    this.onPressed,
    this.large = false,
    this.busy = false,
  });

  final String label;
  final IconData? icon;
  final String? subtitle;
  final FocusNode? focusNode;
  final bool autofocus;
  final VoidCallback? onPressed;

  /// 主操作（播放）用大号
  final bool large;

  /// 图标换成转圈（如「正在加载」）
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final height = large ? 76.0 : 68.0;
    return VFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      onActivate: onPressed,
      semanticLabel: label,
      semanticValue: subtitle,
      radius: VRadius.pill,
      alignment: Alignment.centerLeft,
      showRing: false,
      builder: (context, focused) {
        final fg = onPressed == null ? VColors.textTertiary : (focused ? _darkInk : Colors.white);
        final content = Padding(
          padding: EdgeInsets.only(left: icon == null && !busy ? 32 : 28, right: large ? 40 : 32),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy) ...[
                SizedBox.square(
                  dimension: large ? 26 : 22,
                  child: CircularProgressIndicator(
                    value: VMotion.reduced(context) ? 0.75 : null,
                    strokeWidth: 3,
                    color: fg,
                  ),
                ),
                const SizedBox(width: 16),
              ] else if (icon != null) ...[
                Icon(icon, size: large ? 32 : 28, color: fg),
                const SizedBox(width: 12),
              ],
              if (subtitle == null)
                Text(
                  label,
                  style: TextStyle(
                    fontSize: large ? 26 : 24,
                    fontWeight: large ? FontWeight.w700 : FontWeight.w500,
                    color: fg,
                  ),
                )
              else
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: fg, height: 1.2),
                    ),
                    Text(subtitle!, style: TextStyle(fontSize: 16, color: fg.withValues(alpha: 0.6), height: 1.2)),
                  ],
                ),
            ],
          ),
        );
        return _ButtonSurface(focused: focused, height: height, shape: const StadiumBorder(), child: content);
      },
    );
  }
}

/// 圆形图标按钮（收藏、已看、更多）。
class CircleIconButton extends StatelessWidget {
  const CircleIconButton({super.key, required this.icon, required this.tooltip, this.focusNode, this.onPressed});

  final IconData icon;
  final String tooltip;
  final FocusNode? focusNode;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return VFocusable(
      semanticLabel: tooltip,
      focusNode: focusNode,
      onActivate: onPressed,
      radius: 34,
      showRing: false,
      builder: (context, focused) => _ButtonSurface(
        focused: focused,
        height: 68,
        width: 68,
        shape: const CircleBorder(),
        child: Icon(
          icon,
          size: 28,
          color: onPressed == null ? VColors.textTertiary : (focused ? _darkInk : Colors.white),
        ),
      ),
    );
  }
}

class _ButtonSurface extends StatelessWidget {
  const _ButtonSurface({
    required this.focused,
    required this.height,
    required this.shape,
    required this.child,
    this.width,
  });

  final bool focused;
  final double height;
  final double? width;
  final ShapeBorder shape;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (focused) {
      // 不能用 Container.alignment：在宽布局里它会把按钮撑满整行
      return Container(
        height: height,
        width: width,
        decoration: ShapeDecoration(
          color: Colors.white,
          shape: shape,
          // Windows 用柔和阴影；电视用外发光，远处也能看清焦点
          shadows: PlatformProfile.isDesktop
              ? const [BoxShadow(color: Color(0x40000000), blurRadius: 20, offset: Offset(0, 8))]
              : const [
                  BoxShadow(color: Color(0x47FFFFFF), spreadRadius: 4),
                  BoxShadow(color: Color(0x73A0B4FF), blurRadius: 50, offset: Offset(0, 18)),
                ],
        ),
        child: Center(widthFactor: 1, child: child),
      );
    }
    return Glass(
      radius: height / 2,
      blur: 24,
      fill: const Color(0x1FFFFFFF),
      border: const Color(0x2EFFFFFF),
      height: height,
      width: width,
      child: Center(widthFactor: 1, child: child),
    );
  }
}
