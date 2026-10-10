import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/config/config_store.dart';
import '../data/media/server_registry.dart';
import '../player/playback_cache.dart';
import '../ui/widgets/cached_image.dart';
import '../player/preload.dart';
import '../data/index/index_sync.dart';
import '../features/update/update_controller.dart';
import '../features/update/update_dialog.dart';

import '../ui/scale/design_scale.dart';
import '../ui/widgets/toast.dart';
import 'input/back_handler.dart';
import 'input/intents.dart';
import 'router.dart';
import 'shell.dart';
import 'platform_profile.dart';
import 'theme.dart';
import 'window_frame.dart';
import '../ui/focus/input_mode.dart';

/// 启动时的后台任务（检查更新、同步聚合索引）；测试环境中关闭。
bool autoCheckUpdatesOnLaunch = true;

class VioraApp extends ConsumerStatefulWidget {
  const VioraApp({super.key});

  @override
  ConsumerState<VioraApp> createState() => _VioraAppState();
}

class _VioraAppState extends ConsumerState<VioraApp> {
  late final GoRouter _router = buildRouter();
  DateTime? _lastBackOnHome;

  /// Windows 标题栏的返回按钮是否显示：不在顶层页面（首页 / 资源库 / 搜索 / 收藏 / 记录 / 设置）时显示
  final _canGoBack = ValueNotifier(false);

  static const _tabRoots = {'/', '/library', '/search', '/favorites', '/history', '/settings'};

  void _updateCanGoBack() {
    _canGoBack.value = !_tabRoots.contains(_router.routerDelegate.currentConfiguration.uri.path);
  }

  @override
  void initState() {
    super.initState();
    InputMode.install();
    _router.routerDelegate.addListener(_updateCanGoBack);
    _autoCheckUpdate();
    // 上次异常退出时残留的播放缓存
    if (ref.read(configProvider).playback.clearCacheOnExit) PlaybackCache.clear();
    if (autoCheckUpdatesOnLaunch) {
      // 稍后在后台：各服务器线路测速（选最快线路、更新在线状态），再同步聚合索引（docs/04-aggregation.md §2）
      Future<void>.delayed(const Duration(seconds: 1), () async {
        await Future.wait(
          ref.read(configProvider).servers.map((s) async {
            try {
              await ref.read(serverClientProvider(s.id))?.probeAll().timeout(const Duration(seconds: 10));
            } catch (_) {}
          }),
        );
        // 等首页加载完再在后台同步索引，不和首页抢服务器资源
        await Future<void>.delayed(const Duration(seconds: 8));
        await ref.read(indexSyncProvider.notifier).syncAll();
      });
      CachedNetImage.prune();
    }
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
    _router.routerDelegate.removeListener(_updateCanGoBack);
    _canGoBack.dispose();
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

    // 只有 TV 在首页再按一次退出；Windows 由窗口关闭按钮退出。
    if (!PlatformProfile.isTv) return;
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
    final playback = ref.watch(configProvider.select((c) => c.playback));
    PlaybackPreloader.enabled = playback.preload;
    PlaybackPreloader.warmBytes = playback.warmMb * 1024 * 1024;
    return MaterialApp.router(
      title: 'Viora',
      // 固定简体中文：系统控件显示中文，且汉字使用简体字形（避免部分设备显示成日文字形）
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
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
        FullScreenIntent: CallbackAction<FullScreenIntent>(onInvoke: (_) => toggleFullScreen()),
      },
      // Material 提供默认文字样式（否则文字会以调试样式渲染）。
      builder: (context, child) => Material(
        type: MaterialType.transparency,
        child: _WithTitleBar(
          canGoBack: _canGoBack,
          onBack: _handleBack,
          // Windows 离屏幕近，界面按 2240 宽的画布缩放（比电视的 1920 小约 15%），更精致
          child: DesignScale(
            designWidth: PlatformProfile.isDesktop ? 2240 : 1920,
            child: Stack(
              children: [
                ?child,
                const Positioned.fill(child: ToastOverlay()),
              ],
            ),
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

/// Windows：标题栏叠在最上层，不参与 1920 画布缩放
/// 鼠标侧键（后退键）也触发返回。
class _WithTitleBar extends StatelessWidget {
  const _WithTitleBar({required this.child, required this.canGoBack, required this.onBack});

  final Widget child;
  final ValueListenable<bool> canGoBack;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    if (!PlatformProfile.isDesktop) return child;
    return Listener(
      onPointerDown: (e) {
        if (e.buttons & kBackMouseButton != 0) onBack();
      },
      child: Stack(
        children: [
          Positioned.fill(child: child),
          if (isDesktopWindow)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: WindowTitleBar(canGoBack: canGoBack, onBack: onBack),
            ),
        ],
      ),
    );
  }
}
