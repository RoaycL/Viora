import 'dart:ffi';

typedef _ShowWindowNative = Int32 Function(IntPtr hwnd, Int32 cmd);
typedef _ShowWindowDart = int Function(int hwnd, int cmd);

const _swMinimize = 6;

/// 直接调用 Win32 ShowWindow(SW_MINIMIZE) 最小化窗口。
///
/// window_manager 的 minimize() 在全屏时什么都不做（照搬 Chromium 的「全屏窗口不最小化」），
/// 全屏下点标题栏的最小化按钮就没反应。这里绕过它；窗口保持全屏样式，从任务栏点回来时还是全屏。
bool nativeMinimize(int hwnd) {
  try {
    final showWindow = DynamicLibrary.open('user32.dll')
        .lookupFunction<_ShowWindowNative, _ShowWindowDart>('ShowWindow');
    showWindow(hwnd, _swMinimize);
    return true;
  } catch (_) {
    return false;
  }
}
