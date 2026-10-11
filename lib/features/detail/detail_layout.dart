import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../ui/focus/row_focus.dart';
import '../../ui/widgets/backdrop.dart';
import '../../ui/widgets/server_image.dart' show placeholderArt;
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
                  SizedBox(
                    height: HomeHero.heightOf(context),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // 内容贴底：标题、简介长短只向上延伸，按钮位置固定
                        Positioned(
                          left: VSpace.safeH,
                          right: VSpace.safeH,
                          bottom: 56,
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
