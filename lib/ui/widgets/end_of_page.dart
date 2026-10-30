import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// 页面底部的「已经到底了」：代替大片留空，滚到底时告诉用户没有更多内容
class EndOfPage extends StatelessWidget {
  // 命名参数不能是私有的，只能在初始化列表里赋值
  // ignore: prefer_initializing_formals
  const EndOfPage({super.key, double? leading}) : _leading = leading;

  /// 左边距（与页面内容对齐）
  final double? _leading;

  /// 默认与内容左边距对齐（电视和 Windows 不同）
  double get leading => _leading ?? VSpace.contentLeft;

  @override
  Widget build(BuildContext context) {
    const line = Expanded(child: Divider(color: Color(0x1FFFFFFF), height: 1));
    return Padding(
      padding: EdgeInsets.fromLTRB(leading, 48, VSpace.safeH, 24),
      child: Row(
        children: [
          line,
          const SizedBox(width: 20),
          Text('已经到底了', style: VText.caption.copyWith(color: VColors.textTertiary)),
          const SizedBox(width: 20),
          line,
        ],
      ),
    );
  }
}
