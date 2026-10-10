import 'package:flutter/services.dart';

/// 最近一次交互是鼠标还是按键（遥控器 / 键盘 / 手柄）。
///
/// 键盘 / 遥控器移动焦点时，页面要自动滚动让焦点保持在视野里（关键线滚动）；
/// 鼠标悬停 / 点击带来的焦点变化则不滚动，布局保持不动，滚动交给滚轮和拖动。
abstract final class InputMode {
  static bool _pointer = false;
  static bool _installed = false;

  /// 最近一次交互来自鼠标
  static bool get pointer => _pointer;

  static void markPointer() => _pointer = true;

  /// 焦点变化时是否应该自动滚动
  static bool get shouldAutoScroll => !_pointer;

  static void install() {
    if (_installed) return;
    _installed = true;
    HardwareKeyboard.instance.addHandler((event) {
      _pointer = false;
      return false;
    });
  }
}
