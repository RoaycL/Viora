import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/update/update_controller.dart';
import '../features/update/update_dialog.dart';

import '../ui/scale/design_scale.dart';
import '../ui/widgets/toast.dart';
import 'input/back_handler.dart';
import 'input/intents.dart';
import 'router.dart';
import 'shell.dart';
import 'theme.dart';

/// 测试环境中关闭启动时的自动检查更新。
bool autoCheckUpdatesOnLaunch = true;

class VioraApp extends ConsumerStatefulWidget {
  const VioraApp({super.key});

  @override
  ConsumerState<VioraApp> createState() => _VioraAppState();
}

class _VioraAppState extends ConsumerState<VioraApp> {
  late final GoRouter _router = buildRouter();
  DateTime? _lastBackOnHome;

  @override
  void initState() {
    super.initState();
    _autoCheckUpdate();
  }

  /// 启动后稍等片刻再静默检查更新，有新版本时弹窗。
  Future<void> _autoCheckUpdate() async {
    if (!autoCheckUpdatesOnLaunch) return;
    final controller = ref.read(updateControllerProvider.notifier);
    try {
      await controller.loadSettings();
    } catch (_) {
      // 设置读取失败时按默认值（自动检查）处理
    }
    if (!controller.settings.autoCheck) return;
    await Future<void>.delayed(const Duration(seconds: 3));
    final info = await controller.check(silent: true);
    final context = rootNavigatorKey.currentContext;
    if (info != null && context != null && context.mounted) await showUpdateDialog(context, info);
  }

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

    final path = _router.routerDelegate.currentConfiguration.uri.path;
    if (path != '/') {
      _router.go(parentLocation(path));
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

/// 应用壳内页面的上一级：媒体库网格 → 服务器 → 资源库；其他顶层页面 → 首页。
String parentLocation(String path) {
  final server = RegExp(r'^(/library/server/[^/]+)/lib/').firstMatch(path);
  if (server != null) return server[1]!;
  if (path.startsWith('/library/')) return '/library';
  return '/';
}
