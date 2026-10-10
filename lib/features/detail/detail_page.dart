import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../ui/widgets/backdrop.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/toast.dart';
import '../home/home_mock.dart';

/// 详情页首屏（效果图：详情页 · 首屏）。
/// 选集、播放资源面板、演职员等下滑内容在 M3 / M4 接入真实数据时实现。
class DetailPage extends StatelessWidget {
  const DetailPage({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    final t = HomeMock.find(id) ?? HomeMock.heroes.first;
    final meta = [
      if (t.year != null) '${t.year}',
      if (t.genres.isNotEmpty) t.genres,
      if (t.resources > 0) '${t.resources} 个资源' else '暂无可用资源',
    ].join('  •  ');
    return Material(
      color: VColors.background,
      child: Stack(
        children: [
          Positioned.fill(child: PageBackdrop(art: t.art, fadeBottomFrom: 0.55)),
          const Positioned(
            left: VSpace.safeH,
            top: VSpace.safeV,
            child: Text('按返回键回到上一页', style: TextStyle(fontSize: 20, color: VColors.textTertiary)),
          ),
          Positioned(
            left: VSpace.safeH,
            top: 150,
            width: 980,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.title, style: VText.display.copyWith(fontSize: t.title.length > 6 ? 88 : 120)),
                if (t.latinTitle != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 4),
                    child: Text(
                      t.latinTitle!,
                      style: const TextStyle(fontSize: 22, letterSpacing: 16, color: Color(0xB8FFFFFF)),
                    ),
                  ),
                const SizedBox(height: 24),
                Text(meta, style: const TextStyle(fontSize: 22, color: Color(0xCCFFFFFF))),
                const SizedBox(height: 18),
                if (t.rating != null)
                  Row(
                    children: [
                      const Icon(Icons.star_rounded, color: VColors.rating, size: 26),
                      const SizedBox(width: 6),
                      Text(
                        t.rating!.toStringAsFixed(1),
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: VColors.rating),
                      ),
                      const SizedBox(width: 10),
                      const Text('TMDB', style: TextStyle(fontSize: 18, color: VColors.textTertiary)),
                    ],
                  ),
                const SizedBox(height: 18),
                SizedBox(
                  width: 820,
                  child: Text(
                    t.overview.isEmpty ? '简介将从媒体库获取，缺失时由 TMDB 补全。' : t.overview,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: VText.body.copyWith(color: const Color(0xCCFFFFFF), height: 1.65),
                  ),
                ),
                const SizedBox(height: 40),
                Row(
                  children: [
                    PillButton(
                      autofocus: true,
                      large: true,
                      icon: t.resources > 0 ? Icons.play_arrow_rounded : Icons.search_rounded,
                      label: t.resources > 0 ? '播放' : '暂无资源 · 去搜索',
                      onPressed: () => showToast(t.resources > 0 ? '播放器将在 M1 / M2 接入' : '聚合搜索将在 M3 实现'),
                    ),
                    const SizedBox(width: 40),
                    if (t.resources > 0) ...[
                      PillButton(
                        icon: Icons.swap_horiz_rounded,
                        label: '4K · HDR10',
                        subtitle: '共 ${t.resources} 个资源',
                        onPressed: () => showToast('播放资源选择将在 M3 实现'),
                      ),
                      const SizedBox(width: 18),
                    ],
                    CircleIconButton(
                      icon: Icons.favorite_border_rounded,
                      tooltip: '收藏',
                      onPressed: () => showToast('已加入收藏'),
                    ),
                    const SizedBox(width: 18),
                    CircleIconButton(icon: Icons.check_rounded, tooltip: '标记已看', onPressed: () => showToast('已标记为已看')),
                    const SizedBox(width: 18),
                    CircleIconButton(
                      icon: Icons.more_horiz_rounded,
                      tooltip: '更多',
                      onPressed: () => showToast('更多操作将在 M3 实现'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Positioned(
            left: VSpace.safeH,
            bottom: VSpace.safeV,
            child: Text('选集、播放资源、演职员、相似作品将在 M3 / M4 实现', style: TextStyle(fontSize: 20, color: VColors.textTertiary)),
          ),
        ],
      ),
    );
  }
}
