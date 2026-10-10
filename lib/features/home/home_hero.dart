import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../ui/focus/row_focus.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/status_bar.dart';
import 'home_mock.dart';

/// 首页 Hero（效果图：首页 · 焦点在 Hero 播放按钮）。
///
/// 焦点在 Hero 按钮上且 8 秒无操作时自动轮播到下一部；按钮行作为第 0 行参与行导航。
class HomeHero extends StatefulWidget {
  const HomeHero({
    super.key,
    required this.rowIndex,
    required this.items,
    required this.index,
    required this.onIndexChanged,
    required this.onFocused,
    required this.onPlay,
    required this.onDetail,
  });

  static const height = 660.0;
  static const rotateEvery = Duration(seconds: 8);

  final int rowIndex;
  final List<MockTitle> items;
  final int index;
  final ValueChanged<int> onIndexChanged;
  final VoidCallback onFocused;
  final ValueChanged<MockTitle> onPlay;
  final ValueChanged<MockTitle> onDetail;

  @override
  State<HomeHero> createState() => HomeHeroState();
}

class HomeHeroState extends State<HomeHero> implements FocusRowHandle {
  late final List<FocusNode> _nodes = List.generate(3, (i) {
    final node = FocusNode(debugLabel: 'hero#$i');
    node.addListener(() => _onFocusChanged(i, node));
    return node;
  });
  RowFocusController? _controller;
  int _remembered = 0;
  Timer? _rotate;

  bool get hasFocus => _nodes.any((n) => n.hasFocus);

  @override
  int get length => _nodes.length;

  @override
  FocusNode nodeAt(int index) => _nodes[index];

  @override
  int get rememberedIndex => _remembered;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = RowFocusScope.of(context);
    if (!identical(controller, _controller)) {
      _controller?.unregister(widget.rowIndex, this);
      _controller = controller..register(widget.rowIndex, this);
    }
  }

  @override
  void dispose() {
    _rotate?.cancel();
    _controller?.unregister(widget.rowIndex, this);
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _onFocusChanged(int i, FocusNode node) {
    if (node.hasPrimaryFocus) {
      _remembered = i;
      widget.onFocused();
    }
    // 每次焦点变化都重置轮播计时；焦点离开 Hero 时停止。
    _rotate?.cancel();
    if (hasFocus) {
      _rotate = Timer.periodic(HomeHero.rotateEvery, (_) {
        widget.onIndexChanged((widget.index + 1) % widget.items.length);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.items[widget.index];
    return SizedBox(
      height: HomeHero.height,
      child: Stack(
        children: [
          Positioned(
            left: VSpace.contentLeft,
            top: 150,
            width: 900,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedSwitcher(
                  duration: VMotion.backdrop,
                  layoutBuilder: (current, previous) =>
                      Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
                  child: _HeroInfo(key: ValueKey(t.id), title: t),
                ),
                const SizedBox(height: 34),
                Row(
                  children: [
                    PillButton(
                      focusNode: _nodes[0],
                      autofocus: true,
                      large: true,
                      icon: Icons.play_arrow_rounded,
                      label: '播放 第1季 · 第1集',
                      onPressed: () => widget.onPlay(t),
                    ),
                    const SizedBox(width: 40),
                    PillButton(
                      focusNode: _nodes[1],
                      icon: Icons.info_outline_rounded,
                      label: '详情',
                      onPressed: () => widget.onDetail(t),
                    ),
                    const SizedBox(width: 20),
                    CircleIconButton(focusNode: _nodes[2], icon: Icons.favorite_border_rounded, tooltip: '收藏'),
                  ],
                ),
              ],
            ),
          ),
          // 状态栏随 Hero 一起滚走，不遮挡下方内容
          const Positioned(right: VSpace.safeH, top: VSpace.safeV, child: StatusBar()),
          Positioned(
            right: VSpace.safeH,
            top: 600,
            child: Row(
              children: [
                for (var i = 0; i < widget.items.length; i++)
                  AnimatedContainer(
                    duration: VMotion.scroll,
                    margin: const EdgeInsets.only(left: 10),
                    width: i == widget.index ? 36 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: i == widget.index ? Colors.white : const Color(0x59FFFFFF),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroInfo extends StatelessWidget {
  const _HeroInfo({super.key, required this.title});

  final MockTitle title;

  @override
  Widget build(BuildContext context) {
    final t = title;
    const dot = Text('  •  ', style: TextStyle(fontSize: 22, color: Color(0x66FFFFFF)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: const Color(0x24FFFFFF), borderRadius: BorderRadius.circular(8)),
              child: const Text('今日趋势', style: TextStyle(fontSize: 20, letterSpacing: 1)),
            ),
            const SizedBox(width: 12),
            Text(
              '${t.subtitle} · ${t.resources} 个资源',
              style: const TextStyle(fontSize: 20, color: Color(0xB8FFFFFF), letterSpacing: 2),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Text(
          t.title,
          style: VText.display.copyWith(
            shadows: const [Shadow(color: Color(0x73000000), blurRadius: 40, offset: Offset(0, 6))],
          ),
        ),
        if (t.latinTitle != null)
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 4),
            child: Text(
              t.latinTitle!,
              style: const TextStyle(fontSize: 22, letterSpacing: 16, color: Color(0xB8FFFFFF)),
            ),
          ),
        const SizedBox(height: 22),
        DefaultTextStyle.merge(
          style: const TextStyle(fontSize: 22, color: Color(0xD1FFFFFF)),
          child: Row(
            children: [
              Text('${t.year}'),
              dot,
              Text(t.genres),
              dot,
              const Icon(Icons.star_rounded, size: 24, color: VColors.rating),
              const SizedBox(width: 4),
              Text(
                t.rating!.toStringAsFixed(1),
                style: const TextStyle(color: VColors.rating, fontWeight: FontWeight.w600),
              ),
              for (final b in t.badges) ...[
                const SizedBox(width: 14),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0x66FFFFFF)),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(b, style: const TextStyle(fontSize: 18)),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 22),
        SizedBox(
          width: 780,
          child: Text(
            t.overview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: VText.body.copyWith(color: const Color(0xC7FFFFFF)),
          ),
        ),
      ],
    );
  }
}
