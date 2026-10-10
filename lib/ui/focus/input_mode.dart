import 'package:flutter/gestures.dart';
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

  /// 鼠标最近的位置（窗口坐标）：右键菜单在这里弹出
  static Offset? lastPointer;

  /// 最近一次操作（按键 / 鼠标移动、点击、滚轮）的时间：首页轮播在无操作一段时间后才自动切换
  static DateTime lastInteraction = DateTime.now();

  static Duration get idle => DateTime.now().difference(lastInteraction);

  /// 焦点变化时是否应该自动滚动
  static bool get shouldAutoScroll => !_pointer;

  static void install() {
    if (_installed) return;
    _installed = true;
    HardwareKeyboard.instance.addHandler((event) {
      _pointer = false;
      lastInteraction = DateTime.now();
      return false;
    });
    GestureBinding.instance.pointerRouter.addGlobalRoute((event) {
      if (event is PointerDownEvent || event is PointerHoverEvent) lastPointer = event.position;
      if (event is PointerDownEvent ||
          event is PointerHoverEvent ||
          event is PointerMoveEvent ||
          event is PointerScrollEvent) {
        lastInteraction = DateTime.now();
      }
    });
  }
}
