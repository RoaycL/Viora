import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../ui/focus/row_focus.dart';
import '../../ui/widgets/backdrop.dart';
import '../../ui/widgets/server_image.dart' show placeholderArt;
import '../../ui/widgets/buttons.dart';
import '../home/home_hero.dart';

/// 详情页布局（媒体库详情、TMDB 详情共用），和首页 Hero 一致：
/// 首屏是大幅背景图，标题、简介、按钮贴在首屏底部；剧集、播放资源、演职员等往下滚动查看，滚动时背景逐渐压暗。
class DetailLayout extends StatefulWidget {
  const DetailLayout({
    super.key,
    required this.backdrop,
    required this.seed,
    required this.info,
    required this.buttons,
    required this.below,
  });

  /// 背景图（铺满全屏）
  final Widget? backdrop;

  /// 背景图加载前的占位色（按条目生成，避免每页都一样）
  final String seed;

  /// 标题、元信息、简介
  final Widget info;

  /// 按钮行（第 0 行焦点）
  final Widget buttons;

  /// 首屏下方的内容
  final List<Widget> below;

  @override
  State<DetailLayout> createState() => _DetailLayoutState();
}

class _DetailLayoutState extends State<DetailLayout> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: PageBackdrop(art: placeholderArt(widget.seed), image: widget.backdrop, imageKey: widget.seed),
        ),
        // 往下看剧集、资源时整体压暗背景
        Positioned.fill(
          child: IgnorePointer(
            child: ListenableBuilder(
              listenable: _scroll,
              builder: (context, _) {
                final offset = _scroll.hasClients ? _scroll.offset : 0.0;
                return ColoredBox(color: VColors.background.withValues(alpha: (offset / 500).clamp(0.0, 1.0) * 0.5));
              },
            ),
          ),
        ),
        Positioned.fill(
          child: RowFocusScope(
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    constraints: BoxConstraints(minHeight: HomeHero.heightOf(context)),
                    padding: const EdgeInsets.fromLTRB(VSpace.safeH, 72, VSpace.safeH, 56),
                    alignment: Alignment.bottomLeft,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 1000, child: widget.info),
                        const SizedBox(height: 36),
                        widget.buttons,
                      ],
                    ),
                  ),
                  ...widget.below,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 静态骨架保留详情页构图，不添加循环 ticker、模糊或图片请求。
class DetailLoading extends StatelessWidget {
  const DetailLoading({super.key, required this.seed, required this.onBack});
  final String seed;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => DetailLayout(
    seed: seed,
    backdrop: null,
    info: Semantics(
      liveRegion: true,
      label: '正在加载详情',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Skeleton(width: 520, height: 80),
            const SizedBox(height: 28),
            const _Skeleton(width: 380, height: 22),
            const SizedBox(height: 24),
            for (var i = 0; i < 3; i++) ...[
              _Skeleton(width: i == 2 ? 600 : 850, height: 20),
              const SizedBox(height: 14),
            ],
          ],
        ),
      ),
    ),
    buttons: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const RowAutoFocus(),
        FocusButtonRow(
          rowIndex: 0,
          scrollable: true,
          children: [
            (node) => PillButton(focusNode: node, label: '返回', icon: Icons.arrow_back_rounded, onPressed: onBack),
          ],
        ),
      ],
    ),
    below: const [],
  );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton({required this.width, required this.height});
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(color: const Color(0x14FFFFFF), borderRadius: BorderRadius.circular(8)),
  );
}
