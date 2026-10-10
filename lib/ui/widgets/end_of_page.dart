import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// 页面底部的「已经到底了」：代替大片留空，滚到底时告诉用户没有更多内容
class EndOfPage extends StatelessWidget {
  const EndOfPage({super.key, this.leading = VSpace.contentLeft});

  /// 左边距（与页面内容对齐）
  final double leading;

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
