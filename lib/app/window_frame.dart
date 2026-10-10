import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

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
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

/// 窗口当前是否全屏（标题栏监听窗口事件更新；播放器的全屏按钮、Esc 键用它）
final windowFullScreen = ValueNotifier(false);

Future<void> toggleFullScreen() async {
  if (!isDesktopWindow) return;
  if (MiniPlayerWindow.active.value) await MiniPlayerWindow.exit();
  final full = !await windowManager.isFullScreen();
  await windowManager.setFullScreen(full);
  windowFullScreen.value = full;
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
      if (_wasFullScreen) {
        await windowManager.setFullScreen(false);
        windowFullScreen.value = false;
      }
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
      if (_wasFullScreen) {
        await windowManager.setFullScreen(true);
        windowFullScreen.value = true;
      }
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
    _refresh();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    final max = await windowManager.isMaximized();
    final full = await windowManager.isFullScreen();
    windowFullScreen.value = full;
    if (!mounted) return;
    setState(() {
      _maximized = max;
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

  @override
  Widget build(BuildContext context) {
    // 全屏时完全隐藏（鼠标移到顶部也不出现），按 F11 / Esc 退出全屏；
    // 播放器小窗时也隐藏（小窗自己的悬停按钮负责拖动、还原、关闭）
    return ValueListenableBuilder<bool>(
      valueListenable: MiniPlayerWindow.active,
      builder: (context, mini, _) => _fullScreen || mini ? const SizedBox.shrink() : _bar(),
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
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: _toggleMaximize,
            ),
          ),
          _CaptionButton(icon: Icons.remove_rounded, tooltip: '最小化', onPressed: windowManager.minimize),
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
