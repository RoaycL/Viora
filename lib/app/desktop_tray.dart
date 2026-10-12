import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'window_frame.dart';

/// Windows：点关闭时「退出应用」还是「最小化到托盘」（系统通知区域）。仅 Windows，电视 / 安卓不涉及。
///
/// 开启后：关闭按钮、Alt+F4、任务栏「关闭窗口」都只隐藏窗口；托盘图标单击恢复，右键菜单可以退出。
/// 设置只存在本机（不随 WebDAV / 局域网同步到其他设备）。
class DesktopTray with TrayListener, WindowListener {
  DesktopTray._();
  static final instance = DesktopTray._();

  static const _key = 'viora.window.closeToTray';

  /// 关闭窗口时最小化到托盘（默认开）
  final closeToTray = ValueNotifier(true);

  /// 窗口隐藏到托盘时为 true（播放器据此暂停）
  final hiddenToTray = ValueNotifier(false);

  bool _trayShown = false;

  Future<void> init() async {
    if (!isDesktopWindow) return;
    try {
      closeToTray.value = (await SharedPreferences.getInstance()).getBool(_key) ?? true;
    } catch (_) {}
    windowManager.addListener(this);
    trayManager.addListener(this);
    // 拦截关闭，由 onWindowClose 决定退出还是隐藏
    await windowManager.setPreventClose(true);
    if (closeToTray.value) await _showTray();
  }

  Future<void> setCloseToTray(bool value) async {
    closeToTray.value = value;
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, value);
    } catch (_) {}
    if (value) {
      await _showTray();
    } else {
      await _hideTray();
    }
  }

  Future<void> _showTray() async {
    if (_trayShown) return;
    try {
      await trayManager.setIcon('assets/images/tray_icon.ico');
      await trayManager.setToolTip('Viora');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: '显示 Viora'),
            MenuItem.separator(),
            MenuItem(key: 'exit', label: '退出'),
          ],
        ),
      );
      _trayShown = true;
    } catch (e) {
      debugPrint('tray init failed: $e');
    }
  }

  Future<void> _hideTray() async {
    if (!_trayShown) return;
    _trayShown = false;
    try {
      await trayManager.destroy();
    } catch (_) {}
  }

  /// 从托盘恢复窗口
  Future<void> restore() async {
    hiddenToTray.value = false;
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  /// 真正退出
  Future<void> quit() async {
    await _hideTray();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowClose() async {
    // 托盘图标创建失败时不能隐藏（否则窗口找不回来），直接退出
    if (closeToTray.value && _trayShown) {
      hiddenToTray.value = true;
      await windowManager.hide();
    } else {
      await quit();
    }
  }

  @override
  void onTrayIconMouseDown() => restore();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        restore();
      case 'exit':
        quit();
    }
  }
}
