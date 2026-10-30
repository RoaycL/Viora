import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/log/app_log.dart';
import '../data/cache/snapshot_cache.dart';
import '../data/tmdb/tmdb_disk_cache.dart';
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
import '../features/sync/webdav_service.dart';

/// 启动时的后台任务（检查更新、同步聚合索引）；测试环境中关闭。
bool autoCheckUpdatesOnLaunch = true;

class VioraApp extends ConsumerStatefulWidget {
  const VioraApp({super.key});

  @override
  ConsumerState<VioraApp> createState() => _VioraAppState();
}

class _VioraAppState extends ConsumerState<VioraApp> with WidgetsBindingObserver {
  late final GoRouter _router = buildRouter(observers: [_BackObserver(_updateCanGoBackAfterFrame)]);

  /// 首页第一次按返回后开始计时，计时期间再按一次退出
  Timer? _exitArmed;
  String? _lastLoggedPath;
  WebDavSync? _webdav;

  /// 电视：首页按返回提示「再按一次返回键退出」，2 秒内再按一次才退出
  static const exitConfirmWindow = Duration(seconds: 2);

  static bool _isBackKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.gameButtonB;

  /// Android 系统的返回（没被按键处理的返回键、返回手势）：电视上一律按应用内返回处理，永远不直接关闭应用
  @override
  Future<bool> didPopRoute() async {
    if (!PlatformProfile.isTv) return false;
    _handleBack();
    return true;
  }

  /// Windows 标题栏的返回按钮是否显示：不在顶层页面（首页 / 资源库 / 搜索 / 收藏 / 记录 / 设置）时显示
  final _canGoBack = ValueNotifier(false);

  static const _tabRoots = {'/', '/library', '/search', '/favorites', '/history', '/settings'};

  void _updateCanGoBack() {
    // 详情页、播放页是压栈打开的（路径不变），所以还要看能不能 pop
    _canGoBack.value = _router.canPop() || !_tabRoots.contains(_router.routerDelegate.currentConfiguration.uri.path);
  }

  /// 路由通知时导航器还没把新页面压进去（canPop 仍是 false），等这一帧建完再算
  void _scheduleCanGoBack() {
    // 记下当前页面（只有路径里的 ID，没有个人信息）：闪退时知道停在哪个页面
    final path = _router.routerDelegate.currentConfiguration.uri.path;
    if (path != _lastLoggedPath) {
      _lastLoggedPath = path;
      AppLog.add('[nav] $path');
    }
    _updateCanGoBack();
    _updateCanGoBackAfterFrame();
  }

  void _updateCanGoBackAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateCanGoBack();
    });
  }

  @override
  void initState() {
    super.initState();
    InputMode.install();
    if (PlatformProfile.isTv) {
      // 先于路由注册：系统返回先到这里
      WidgetsBinding.instance.addObserver(this);
    }
    _router.routerDelegate.addListener(_scheduleCanGoBack);
    _autoCheckUpdate();
    // 上次异常退出时残留的播放缓存
    if (ref.read(configProvider).playback.clearCacheOnExit) PlaybackCache.clear();
    // WebDAV 同步：启动时同步一次，之后配置变化后自动同步（没填 WebDAV 时什么都不做）
    _webdav = WebDavSync.instance = WebDavSync(ProviderScope.containerOf(context, listen: false));
    if (autoCheckUpdatesOnLaunch) _webdav!.start();
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
      // 旧版本把 TMDB 缓存存在 SharedPreferences 里：启动稳定后一次性清掉，并清理磁盘缓存和孤儿快照
      Future<void>.delayed(const Duration(seconds: 15), () async {
        await TmdbDiskCache.dropLegacyPreferences();
        await TmdbDiskCache.prune();
        await SnapshotCache.prune();
      });
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
    if (identical(WebDavSync.instance, _webdav)) WebDavSync.instance = null;
    _webdav?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _exitArmed?.cancel();
    _router.routerDelegate.removeListener(_scheduleCanGoBack);
    _canGoBack.dispose();
    _router.dispose();
    super.dispose();
  }

  /// 返回键（docs/07-input-control.md §2.1）：
  /// 页面自己的处理 → 导航栏回到内容 → 关闭弹层 / 出栈 → 回到首页。退出应用：电视在首页 2 秒内连按两次返回键。
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

    // 首页：电视上第一次按返回提示，2 秒内再按一次退出；Windows 由窗口关闭按钮退出。
    if (!PlatformProfile.isTv) return;
    if (_exitArmed?.isActive ?? false) {
      _exitArmed!.cancel();
      SystemNavigator.pop();
      return;
    }
    _exitArmed = Timer(exitConfirmWindow, () {});
    showToast('再按一次返回键退出 Viora');
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
      // 默认快捷键里的 Esc → 关闭弹层换成应用自己的返回（不响应按住不放的重复事件），两者同时存在时默认的会先匹配
      shortcuts: <ShortcutActivator, Intent>{
        for (final e in WidgetsApp.defaultShortcuts.entries)
          if (!(e.key is SingleActivator && _isBackKey((e.key as SingleActivator).trigger))) e.key: e.value,
        ...appShortcuts,
      },
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

/// 压栈 / 出栈（详情页、播放页）时刷新标题栏的返回按钮
class _BackObserver extends NavigatorObserver {
  _BackObserver(this.onChange);

  final VoidCallback onChange;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => onChange();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => onChange();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => onChange();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => onChange();
}
