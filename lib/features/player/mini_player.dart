import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/window_frame.dart';
import '../../player/engine.dart';

/// Windows 小窗播放的控制层：鼠标移上来才显示。
/// 拖动画面移动窗口，双击还原；按钮：播放 / 暂停、还原大窗口、关闭播放。
///
/// 小窗只有 512 像素宽，整个界面按 2240 设计宽度缩放后只有原来的 1/4，所以这里的尺寸都按缩放后能看清来定。
class MiniPlayerOverlay extends StatefulWidget {
  const MiniPlayerOverlay({
    super.key,
    required this.state,
    required this.title,
    required this.onPlayPause,
    required this.onClose,
  });

  final EngineState state;
  final String title;
  final VoidCallback onPlayPause;
  final VoidCallback onClose;

  @override
  State<MiniPlayerOverlay> createState() => _MiniPlayerOverlayState();
}

class _MiniPlayerOverlayState extends State<MiniPlayerOverlay> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final total = s.duration.inMilliseconds;
    final progress = total <= 0 ? 0.0 : (s.position.inMilliseconds / total).clamp(0.0, 1.0);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => windowManager.startDragging(),
        onDoubleTap: MiniPlayerWindow.exit,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: _hover || !s.playing ? 1 : 0,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0x73000000)),
              Positioned(
                left: 56,
                right: 420,
                top: 40,
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w600),
                ),
              ),
              Positioned(
                right: 32,
                top: 24,
                child: Row(
                  children: [
                    _MiniButton(icon: Icons.open_in_full_rounded, tooltip: '还原', onPressed: MiniPlayerWindow.exit),
                    const SizedBox(width: 16),
                    _MiniButton(icon: Icons.close_rounded, tooltip: '关闭', onPressed: widget.onClose),
                  ],
                ),
              ),
              Center(
                child: _MiniButton(
                  icon: s.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  tooltip: s.playing ? '暂停' : '播放',
                  size: 260,
                  onPressed: widget.onPlayPause,
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 22,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: progress,
                    child: const ColoredBox(color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniButton extends StatefulWidget {
  const _MiniButton({required this.icon, required this.tooltip, required this.onPressed, this.size = 170});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double size;

  @override
  State<_MiniButton> createState() => _MiniButtonState();
}

class _MiniButtonState extends State<_MiniButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hover ? const Color(0x40FFFFFF) : const Color(0x26000000),
            ),
            child: Icon(widget.icon, size: widget.size * 0.62, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
