import 'package:flutter/widgets.dart';

/// 网络图片加载完成后淡入；淡入结束后只留图片本身，不再在下面画占位。
///
/// 之前占位（三层渐变的 [ArtView]）一直垫在每张海报 / 背景下面：图片早就盖住了，
/// 但每次重绘（卡片焦点缩放、滚动、背景切换）都要多画一遍，首页几十张卡片加起来很费 GPU。
class ImageFadeIn extends StatefulWidget {
  const ImageFadeIn({
    super.key,
    required this.loaded,
    required this.placeholder,
    required this.child,
    this.fadeOutPlaceholder = false,
  });

  /// 图片的第一帧已经解码好
  final bool loaded;
  final Widget placeholder;
  final Widget child;

  /// 占位同时淡出（透明图，如 Logo：占位是文字标题，不能和图叠在一起）
  final bool fadeOutPlaceholder;

  static const duration = Duration(milliseconds: 250);

  @override
  State<ImageFadeIn> createState() => _ImageFadeInState();
}

class _ImageFadeInState extends State<ImageFadeIn> {
  bool _done = false;

  @override
  void didUpdateWidget(ImageFadeIn old) {
    super.didUpdateWidget(old);
    // 换了一张还没加载的图（没开 gaplessPlayback 时）：重新显示占位
    if (!widget.loaded) _done = false;
  }

  @override
  Widget build(BuildContext context) {
    // 和下面的 Stack(fit: expand) 一样占满父级给的空间，去掉占位前后图片大小不变
    if (_done && widget.loaded) return SizedBox.expand(child: widget.child);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.fadeOutPlaceholder)
          AnimatedOpacity(opacity: widget.loaded ? 0 : 1, duration: ImageFadeIn.duration, child: widget.placeholder)
        else
          widget.placeholder,
        AnimatedOpacity(
          opacity: widget.loaded ? 1 : 0,
          duration: ImageFadeIn.duration,
          onEnd: () {
            if (mounted && widget.loaded) setState(() => _done = true);
          },
          child: widget.child,
        ),
      ],
    );
  }
}
