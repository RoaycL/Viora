import 'package:flutter/material.dart';

/// 设计令牌，与效果图（docs/06-ui-design.md §2）一致。
/// 所有尺寸都基于 1920×1080 设计画布，由 [DesignScale] 统一缩放。
abstract final class VColors {
  static const background = Color(0xFF07080B);
  static const surface = Color(0xFF14161E);
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xC7FFFFFF); // 78%
  static const textTertiary = Color(0x8CFFFFFF); // 55%
  static const textMuted = Color(0x66FFFFFF); // 40%
  static const accent = Color(0xFFA9B6FF);
  static const rating = Color(0xFFFFD27A);
  static const dolbyVision = Color(0xFFC6B4FF);
  static const ok = Color(0xFF5BE38A);
  static const warn = Color(0xFFFFC56B);
  static const bad = Color(0xFFFF6B6B);
  static const adult = Color(0xFFFF8FA3);

  /// 磨砂玻璃
  static const glassFill = Color(0x14FFFFFF); // 8%
  static const glassFillStrong = Color(0x26FFFFFF); // 15%
  static const glassBorder = Color(0x1FFFFFFF); // 12%
  static const glassHighlight = Color(0x1FFFFFFF);

  /// 焦点
  static const focusRing = Color(0xFFFFFFFF);
  static const focusGlow = Color(0x738CA0FF);
}

abstract final class VSpace {
  /// 安全区（约 5% 过扫描）
  static const safeH = 96.0;
  static const safeV = 54.0;

  /// 收起态导航栏占位（24 外边距 + 88 宽 + 64 间距）
  static const contentLeft = 176.0;
  static const navRailWidth = 88.0;
  static const navRailExpandedWidth = 280.0;

  static const rowGap = 24.0;
  static const sectionGap = 48.0;
}

abstract final class VRadius {
  static const card = 16.0;
  static const panel = 24.0;
  static const pill = 999.0;
}

abstract final class VMotion {
  static const focus = Duration(milliseconds: 150);
  static const scroll = Duration(milliseconds: 250);
  static const backdrop = Duration(milliseconds: 400);
  static const focusScale = 1.08;
}

/// 系统字体回退：Windows 用微软雅黑，Android 用 Noto Sans CJK。
const _fontFallback = <String>[
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'Noto Sans CJK SC',
  'Noto Sans SC',
  'PingFang SC',
  'sans-serif',
];

abstract final class VText {
  static const display = TextStyle(fontSize: 112, fontWeight: FontWeight.w900, height: 1, letterSpacing: 6);
  static const h1 = TextStyle(fontSize: 48, fontWeight: FontWeight.w900, letterSpacing: 2);
  static const h2 = TextStyle(fontSize: 36, fontWeight: FontWeight.w700);
  static const rowTitle = TextStyle(fontSize: 28, fontWeight: FontWeight.w700);
  static const body = TextStyle(fontSize: 24, height: 1.6);
  static const label = TextStyle(fontSize: 22);
  static const caption = TextStyle(fontSize: 20);
  static const small = TextStyle(fontSize: 18);
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(surface: VColors.background, primary: VColors.accent, onPrimary: Color(0xFF0B0C10));
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: VColors.background,
    fontFamilyFallback: _fontFallback,
    // 焦点效果全部由 VFocusable 自绘，关掉 Material 默认高亮。
    focusColor: Colors.transparent,
    hoverColor: Colors.transparent,
    highlightColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: VColors.textPrimary,
      displayColor: VColors.textPrimary,
      fontFamilyFallback: _fontFallback,
    ),
  );
}
