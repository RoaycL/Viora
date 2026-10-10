import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../ui/glass/glass.dart';
import '../../ui/widgets/buttons.dart';

/// 尚未实现的页面（搜索 / 收藏 / 观看记录 / 设置）。
class PlaceholderPage extends StatelessWidget {
  const PlaceholderPage({super.key, required this.title, required this.milestone, required this.description});

  final String title;
  final String milestone;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(VSpace.contentLeft, VSpace.safeV, VSpace.safeH, VSpace.safeV),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: VText.h1),
          const SizedBox(height: 40),
          Glass(
            width: 900,
            padding: const EdgeInsets.all(40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('计划在 $milestone 实现', style: VText.h2.copyWith(fontSize: 30)),
                const SizedBox(height: 16),
                Text(description, style: VText.body.copyWith(color: VColors.textSecondary)),
                const SizedBox(height: 32),
                PillButton(autofocus: true, icon: Icons.home_rounded, label: '回到首页', onPressed: () => context.go('/')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
