import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// 电视低配模式（设置 → 通用，默认开，只存在本机）。
///
/// 开着时关掉弱 GPU 吃不消的视觉效果：毛玻璃实时模糊、骨架屏呼吸、弹幕每秒 60 帧、卡片浮现动画、
/// 光晕模糊。关掉后电视和 Windows 一样显示完整效果（适合性能好的电视盒子）。
/// 图片解码尺寸、缓存大小、并发数、播放缓冲这些和内存、稳定性有关的限制不受它影响，电视上始终保留。
abstract final class PerfMode {
  static const _key = 'viora.tv.liteMode';

  /// 设置值（Windows 上不起作用）
  static final liteSetting = ValueNotifier(true);

  /// 现在是不是低配：电视且开着低配模式
  static bool get lite => PlatformProfile.isTv && liteSetting.value;

  static Future<void> load() async {
    try {
      liteSetting.value = (await SharedPreferences.getInstance()).getBool(_key) ?? true;
    } catch (_) {}
  }

  static Future<void> set(bool value) async {
    liteSetting.value = value;
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, value);
    } catch (_) {}
  }

  @visibleForTesting
  static set debugLite(bool v) => liteSetting.value = v;
}
