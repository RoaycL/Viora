import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_prefs.dart';

/// Windows 沉浸式窗口：去掉系统标题栏，内容铺到窗口顶端，
/// 顶部透明条用于拖动（双击最大化），右上角为自绘的窗口按钮。
bool get isDesktopWindow => !kIsWeb && Platform.isWindows;

Future<void> initDesktopWindow() async {
  if (!isDesktopWindow) return;
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(1600, 900),
    minimumSize: Size(960, 540),
    center: true,
    backgroundColor: Color(0xFF07080B),
    title: 'Viora',
    titleBarStyle: TitleBarStyle.hidden,
  );
  // 本机设置（启动全屏、图标、系统代理）在显示窗口前读好
  await DesktopPrefs.instance.load();
  await SystemProxy.apply(DesktopPrefs.instance.followSystemProxy.value);
  final launchFull = DesktopPrefs.instance.fullScreenOnLaunch.value;
  // 「打开软件时全屏」：窗口先按整块屏幕的大小摆好再显示（无边框，看起来已经是全屏），
  // 不会先闪一下 1600×900 的小窗口再变大。真正进全屏仍等窗口显示、第一帧画完之后，和手动进全屏走同一条路：
  // 之前在窗口还没显示时就进全屏，原生插件记下的「全屏前窗口」不对，之后切回窗口模式画面卡住不动。
  // 这样记下的「全屏前窗口」是整块屏幕大小，退出全屏时 [_applyFullScreen] 会放回屏幕中间的默认大小
  final screen = launchFull ? _primaryScreen() : null;
  await windowManager.waitUntilReadyToShow(options, () async {
    if (screen != null) await windowManager.setBounds(Offset.zero & screen);
    await windowManager.show();
    await windowManager.focus();
  });
  if (launchFull) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 50), () => setWindowFullScreen(true));
    });
  }
}

/// 主屏幕的逻辑尺寸（取不到时为 null）
Size? _primaryScreen() {
  final display = PlatformDispatcher.instance.displays.firstOrNull;
  if (display == null || display.size.isEmpty) return null;
  return display.size / display.devicePixelRatio;
}

/// 窗口当前是否全屏（标题栏监听窗口事件更新；播放器的全屏按钮、Esc 键用它）
final windowFullScreen = ValueNotifier(false);

/// 窗口（不算全屏时）是否最大化。全屏期间保留进全屏前的值，播放页用它记下进来前的窗口状态
final windowMaximized = ValueNotifier(false);

/// 最大化 / 还原窗口（排在进出全屏后面执行；全屏中或已经是目标状态时不动）
Future<void> setWindowMaximized(bool max) {
  if (!isDesktopWindow) return Future<void>.value();
  return _fullScreenChain = _fullScreenChain.then((_) async {
    try {
      if (await windowManager.isFullScreen() || await windowManager.isMaximized() == max) return;
      if (max) {
        await windowManager.maximize();
      } else {
        await windowManager.unmaximize();
      }
    } catch (e) {
      debugPrint('maximize: $e');
    }
  });
}

/// 沉浸：播放页控制层隐藏时，标题栏的窗口按钮也隐藏（鼠标一动控制层出来，标题栏跟着出来）
final windowImmersive = ValueNotifier(false);

/// 进出全屏一次只做一个：连续双击、按钮和快捷键同时触发时，前一次还没切完又切一次，
/// 原生插件记下的「全屏前的窗口位置」会被覆盖成全屏的大小，退出后窗口卡在半截、画面不刷新
Future<void> _fullScreenChain = Future<void>.value();
bool _fullScreenBusy = false;

/// 切换全屏。上一次切换还没完成时忽略（双击连发、按键重复）
Future<void> toggleFullScreen() async {
  if (!isDesktopWindow || _fullScreenBusy) return;
  await setWindowFullScreen(!windowFullScreen.value);
}

/// 进入 / 退出全屏（排队执行，已经是目标状态时不动）
Future<void> setWindowFullScreen(bool full) {
  if (!isDesktopWindow) return Future<void>.value();
  return _fullScreenChain = _fullScreenChain.then((_) async {
    _fullScreenBusy = true;
    try {
      if (MiniPlayerWindow.active.value) await MiniPlayerWindow.exit();
      await _applyFullScreen(full);
    } catch (e) {
      debugPrint('full screen: $e');
    } finally {
      _fullScreenBusy = false;
    }
  });
}

Future<void> _applyFullScreen(bool full) async {
  if (await windowManager.isFullScreen() == full) {
    windowFullScreen.value = full;
    return;
  }
  await windowManager.setFullScreen(full);
  windowFullScreen.value = full;
  if (full || await windowManager.isMaximized()) return;
  // 退回的窗口不该还是整块屏幕那么大（原生插件记错了全屏前的位置时会这样，画面卡在全屏时的样子）：放回屏幕中间的默认大小
  final screen = _primaryScreen();
  final now = await windowManager.getBounds();
  if (screen != null && now.width >= screen.width - 1 && now.height >= screen.height - 1) {
    const size = Size(1600, 900);
    await windowManager.setBounds(
      Rect.fromLTWH((screen.width - size.width) / 2, (screen.height - size.height) / 2, size.width, size.height),
    );
  }
  // 退出全屏后窗口的边框样式变了，但内容区不一定跟着重新布局（画面停在全屏时的样子、像卡死）：
  // 把窗口宽度改 1 像素再改回来，强制重新布局、重绘
  final bounds = await windowManager.getBounds();
  await windowManager.setBounds(Rect.fromLTWH(bounds.left, bounds.top, bounds.width + 1, bounds.height));
  await windowManager.setBounds(bounds);
}

/// 播放器小窗（画中画）：窗口缩小到屏幕右下角并置顶，退出时恢复原来的大小、位置、最大化 / 全屏状态。仅 Windows。
abstract final class MiniPlayerWindow {
  static final active = ValueNotifier(false);
  static Rect? _saved;
  static bool _wasMaximized = false;
  static bool _wasFullScreen = false;
  static bool _busy = false;

  static const size = Size(512, 288);

  static Future<void> enter() async {
    if (!isDesktopWindow || active.value || _busy) return;
    _busy = true;
    try {
      _wasFullScreen = await windowManager.isFullScreen();
      if (_wasFullScreen) await _applyFullScreen(false);
      _wasMaximized = await windowManager.isMaximized();
      if (_wasMaximized) await windowManager.unmaximize();
      _saved = await windowManager.getBounds();
      await windowManager.setMinimumSize(const Size(320, 180));
      final display = PlatformDispatcher.instance.displays.firstOrNull;
      final screen = display == null ? const Size(1920, 1080) : display.size / display.devicePixelRatio;
      // 右下角，留出任务栏的高度
      await windowManager.setBounds(
        Rect.fromLTWH(screen.width - size.width - 24, screen.height - size.height - 72, size.width, size.height),
      );
      await windowManager.setAlwaysOnTop(true);
      active.value = true;
    } finally {
      _busy = false;
    }
  }

  static Future<void> exit() async {
    if (!isDesktopWindow || !active.value || _busy) return;
    _busy = true;
    try {
      active.value = false;
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setMinimumSize(const Size(960, 540));
      if (_saved != null) await windowManager.setBounds(_saved!);
      if (_wasMaximized) await windowManager.maximize();
      if (_wasFullScreen) await _applyFullScreen(true);
    } finally {
      _busy = false;
    }
  }

  static Future<void> toggle() => active.value ? exit() : enter();
}

/// 叠在应用最上层的标题栏（不参与 1920 画布缩放，按真实像素绘制）。
class WindowTitleBar extends StatefulWidget {
  const WindowTitleBar({super.key, required this.canGoBack, required this.onBack});

  /// 当前不在顶层页面时显示左上角的返回按钮
  final ValueListenable<bool> canGoBack;
  final VoidCallback onBack;

  static const height = 34.0;

  @override
  State<WindowTitleBar> createState() => _WindowTitleBarState();
}

class _WindowTitleBarState extends State<WindowTitleBar> with WindowListener {
  bool _maximized = false;
  bool _fullScreen = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // 进出全屏以应用自己记的状态为准（原生插件的全屏事件不一定每次都发，标题栏会停在旧样子几秒）
    windowFullScreen.addListener(_onFullScreenFlag);
    _refresh();
  }

  void _onFullScreenFlag() {
    final full = windowFullScreen.value;
    if (!mounted || full == _fullScreen) return;
    setState(() {
      _fullScreen = full;
      _revealed = false;
    });
  }

  @override
  void dispose() {
    windowFullScreen.removeListener(_onFullScreenFlag);
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    final max = await windowManager.isMaximized();
    final full = await windowManager.isFullScreen();
    windowFullScreen.value = full;
    if (!full) windowMaximized.value = max;
    if (!mounted) return;
    setState(() {
      _maximized = max;
      if (full != _fullScreen) _revealed = false;
      _fullScreen = full;
    });
  }

  @override
  void onWindowMaximize() => _refresh();

  @override
  void onWindowUnmaximize() => _refresh();

  @override
  void onWindowEnterFullScreen() => _refresh();

  @override
  void onWindowLeaveFullScreen() => _refresh();

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  /// 全屏时鼠标移到屏幕最上沿，标题栏滑出来；移开后收回
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    // 播放器小窗时隐藏（小窗自己的悬停按钮负责拖动、还原、关闭）；播放页控制层隐藏时也隐藏
    return ListenableBuilder(
      listenable: Listenable.merge([MiniPlayerWindow.active, windowImmersive]),
      builder: (context, _) {
        if (MiniPlayerWindow.active.value || windowImmersive.value) return const SizedBox.shrink();
        if (_fullScreen) return _fullScreenBar();
        return _bar();
      },
    );
  }

  /// 全屏：平时只留最上沿几像素的感应区（translucent，不挡下面的内容），鼠标碰到就淡入整条标题栏
  Widget _fullScreenBar() {
    return SizedBox(
      height: WindowTitleBar.height,
      child: Stack(
        children: [
          if (!_revealed)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 4,
              child: MouseRegion(
                hitTestBehavior: HitTestBehavior.translucent,
                onEnter: (_) => setState(() => _revealed = true),
              ),
            ),
          IgnorePointer(
            ignoring: !_revealed,
            // 和窗口模式一样直接浮在背景图上，不加底色；只淡入淡出
            child: AnimatedOpacity(
              opacity: _revealed ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              child: MouseRegion(
                onExit: (_) => setState(() => _revealed = false),
                child: _bar(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bar() {
    return SizedBox(
      height: WindowTitleBar.height,
      child: Row(
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: widget.canGoBack,
            builder: (context, canGoBack, _) => canGoBack
                ? _CaptionButton(icon: Icons.arrow_back_rounded, tooltip: '返回', onPressed: () async => widget.onBack())
                : const SizedBox.shrink(),
          ),
          Expanded(
            // opaque：标题栏下面的内容收不到这块区域的鼠标事件。之前是 translucent，
            // 下面的列表（鼠标可以拖动滚动）也参与手势竞争，鼠标一拖常被列表抢走，窗口拖不动
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // 全屏时窗口不能拖动；双击退出全屏
              onPanStart: _fullScreen ? null : (_) => windowManager.startDragging(),
              onDoubleTap: _fullScreen ? toggleFullScreen : _toggleMaximize,
            ),
          ),
          _CaptionButton(icon: Icons.remove_rounded, tooltip: '最小化', onPressed: windowManager.minimize),
          if (_fullScreen)
            const _CaptionButton(icon: Icons.fullscreen_exit_rounded, iconSize: 18, tooltip: '退出全屏', onPressed: toggleFullScreen)
          else
            _CaptionButton(
              icon: _maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
              iconSize: _maximized ? 13 : 16,
              tooltip: _maximized ? '还原' : '最大化',
              onPressed: _toggleMaximize,
            ),
          _CaptionButton(
            icon: Icons.close_rounded,
            tooltip: '关闭',
            hoverColor: const Color(0xFFE81123),
            onPressed: windowManager.close,
          ),
        ],
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.hoverColor = const Color(0x24FFFFFF),
    this.iconSize = 16,
  });

  final IconData icon;
  final String tooltip;
  final Future<void> Function() onPressed;
  final Color hoverColor;
  final double iconSize;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 46,
            height: WindowTitleBar.height,
            color: _hover ? widget.hoverColor : const Color(0x00000000),
            child: Icon(widget.icon, size: widget.iconSize, color: _hover ? Colors.white : const Color(0xB3FFFFFF)),
          ),
        ),
      ),
    );
  }
}
