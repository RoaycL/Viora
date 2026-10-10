import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../ui/scale/design_scale.dart';
import '../ui/widgets/toast.dart';
import 'input/back_handler.dart';
import 'input/intents.dart';
import 'router.dart';
import 'shell.dart';
import 'theme.dart';

class VioraApp extends StatefulWidget {
  const VioraApp({super.key});

  @override
  State<VioraApp> createState() => _VioraAppState();
}

class _VioraAppState extends State<VioraApp> {
  late final GoRouter _router = buildRouter();
  DateTime? _lastBackOnHome;

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  /// 返回键（docs/07-input-control.md §2.1）：
  /// 页面自己的处理 → 导航栏回到内容 → 关闭弹层 / 出栈 → 回到首页 → 再按一次退出。
  void _handleBack() {
    if (backDispatcher.dispatch()) return;

    final shell = ShellController.instance;
    if (shell.railHasFocus) {
      shell.focusContent();
      return;
    }

    final navigator = rootNavigatorKey.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
      return;
    }

    if (_router.routerDelegate.currentConfiguration.uri.path != '/') {
      _router.go('/');
      return;
    }

    // 只有 Android（TV）在首页再按一次退出；Windows 由窗口关闭按钮退出。
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final now = DateTime.now();
    if (_lastBackOnHome != null && now.difference(_lastBackOnHome!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
    } else {
      _lastBackOnHome = now;
      showToast('再按一次返回键退出');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Viora',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      routerConfig: _router,
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        scrollbars: false,
        dragDevices: PointerDeviceKind.values.toSet(),
      ),
      shortcuts: <ShortcutActivator, Intent>{...WidgetsApp.defaultShortcuts, ...appShortcuts},
      actions: <Type, Action<Intent>>{
        ...WidgetsApp.defaultActions,
        BackIntent: CallbackAction<BackIntent>(onInvoke: (_) => _handleBack()),
        SearchIntent: CallbackAction<SearchIntent>(onInvoke: (_) => _router.go('/search')),
      },
      // Material 提供默认文字样式（否则文字会以调试样式渲染）。
      builder: (context, child) => Material(
        type: MaterialType.transparency,
        child: DesignScale(
          child: Stack(
            children: [
              ?child,
              const Positioned.fill(child: ToastOverlay()),
            ],
          ),
        ),
      ),
    );
  }
}
