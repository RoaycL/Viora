import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../glass/glass.dart';

/// 详情页等全屏页面左上角的返回按钮（只在 Windows 显示：电视用遥控器返回键）。
/// 只响应鼠标，不参与遥控器 / 键盘的焦点移动；键盘用户按 Esc 返回。
class PageBackButton extends StatefulWidget {
  const PageBackButton({super.key});

  @override
  State<PageBackButton> createState() => _PageBackButtonState();
}

class _PageBackButtonState extends State<PageBackButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    if (!PlatformProfile.isDesktop) return const SizedBox.shrink();
    return Positioned(
      left: 48,
      top: 48,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () => context.canPop() ? context.pop() : context.go('/'),
          child: Tooltip(
            message: '返回（Esc）',
            child: AnimatedScale(
              scale: _hover ? 1.06 : 1,
              duration: VMotion.focus,
              child: Glass(
                radius: 999,
                blur: 16,
                fill: _hover ? const Color(0x40FFFFFF) : const Color(0x26000000),
                padding: const EdgeInsets.all(14),
                child: const Icon(Icons.arrow_back_rounded, size: 30, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
