import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../widgets/status_bar.dart';

/// Windows 右上角：服务器在线状态 + 时间、搜索按钮（和电视顶部标签栏右侧一样）。
/// 用鼠标点；键盘用 Ctrl+F 或 / 打开搜索，所以不参与方向键焦点
class TopRightBar extends StatelessWidget {
  const TopRightBar({super.key, required this.searchActive, required this.onSearch});

  /// 当前在搜索页（图标常亮）
  final bool searchActive;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return ExcludeFocus(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const StatusBar(compact: true),
          const SizedBox(width: 14),
          _SearchButton(active: searchActive, onTap: onSearch),
        ],
      ),
    );
  }
}

class _SearchButton extends StatefulWidget {
  const _SearchButton({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  State<_SearchButton> createState() => _SearchButtonState();
}

class _SearchButtonState extends State<_SearchButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final lit = _hover;
    return Tooltip(
      message: '搜索（Ctrl+F）',
      waitDuration: const Duration(milliseconds: 500),
      child: Semantics(
        button: true,
        selected: widget.active,
        label: '搜索',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: VMotion.duration(context, VMotion.focus),
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: lit
                    ? Colors.white
                    : widget.active
                    ? const Color(0x33FFFFFF)
                    : const Color(0x1FFFFFFF),
                border: Border.all(color: const Color(0x1AFFFFFF)),
              ),
              child: Icon(
                Icons.search_rounded,
                size: 28,
                color: lit
                    ? VColors.background
                    : widget.active
                    ? Colors.white
                    : const Color(0xD9FFFFFF),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
