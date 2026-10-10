import 'dart:io';

import 'package:flutter/foundation.dart';

/// 运行平台的操作方式（docs/07-input-control.md §0）。
///
/// 所有"电视和电脑操作不同"的地方都从这里判断，不要在页面里各自写 Platform 判断。
enum PlatformProfile {
  /// Android TV：遥控器（D-pad）为主，界面上不放返回按钮，用屏幕键盘输入
  tv,

  /// Windows：键盘 + 鼠标，界面上有返回按钮、窗口按钮，支持悬停、滚轮、拖动、物理键盘输入
  desktop;

  static PlatformProfile current = !kIsWeb && Platform.isAndroid ? tv : desktop;

  /// 测试用：模拟电视 / 电脑的操作逻辑
  @visibleForTesting
  static set debugOverride(PlatformProfile p) => current = p;

  static bool get isTv => current == tv;
  static bool get isDesktop => current == desktop;
}
