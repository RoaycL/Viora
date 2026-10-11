import 'package:flutter/material.dart';

import '../../data/cache/snapshot_cache.dart';

import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/platform_profile.dart';

import '../../ui/widgets/fill_grid.dart';

import '../../app/theme.dart';
import '../../data/config/config_store.dart';
import '../../data/index/media_index.dart';
import '../../data/media/media_models.dart';
import '../../data/media/server_registry.dart';
import '../../ui/focus/focus_auto_scroll.dart';
import '../../ui/rows/cards.dart';
import '../browse/media_cards.dart';

/// 所有已登录服务器上收藏的电影 / 剧集，同一部作品合并
final favoritesProvider = FutureProvider<List<AggregatedTitle>>((ref) async {
  ref.watch(configProvider.select((c) => c.serversKey));
  final config = ref.read(configProvider);
  final servers = config.servers.where((s) => s.loggedIn);
  // 启动时先显示上次的收藏，后台再拉最新
  final items = await snapshotFirst(
    ref,
    'favorites',
    encode: MediaItem.encodeList,
    decode: (j) => [
      for (final it in MediaItem.decodeList(j))
        if (itemVisible(config, it)) it,
    ],
    fetch: () async {
      final lists = await Future.wait(
        servers.map((s) async {
          try {
            final page = await ref
                .read(serverClientProvider(s.id))!
                .items(filters: 'IsFavorite', limit: 200, sortBy: 'SortName', sortOrder: 'Ascending')
                .timeout(const Duration(seconds: 10));
            return page.items;
          } catch (_) {
            return const <MediaItem>[];
          }
        }),
      );
      return [for (final l in lists) ...l];
    },
  );
  return groupTitles(items);
});

/// 最近看过：已看完的电影 / 单集按观看时间倒序，同一部剧只保留最近的一集
final recentlyPlayedProvider = FutureProvider<List<MediaItem>>((ref) async {
  ref.watch(configProvider.select((c) => c.serversKey));
  final config = ref.read(configProvider);
  final servers = config.servers.where((s) => s.loggedIn);
  // 启动时先显示上次的记录，后台再拉最新
  return snapshotFirst(
    ref,
    'recently-played',
    encode: MediaItem.encodeList,
    decode: (j) => [
      for (final it in MediaItem.decodeList(j))
        if (itemVisible(config, it)) it,
    ],
    fetch: () async {
      final lists = await Future.wait(
        servers.map((s) async {
          try {
            final page = await ref
                .read(serverClientProvider(s.id))!
                .items(
                  types: 'Movie,Episode',
                  filters: 'IsPlayed',
                  limit: 60,
                  sortBy: 'DatePlayed',
                  sortOrder: 'Descending',
                )
                .timeout(const Duration(seconds: 10));
            return page.items;
          } catch (_) {
            return const <MediaItem>[];
          }
        }),
      );
      return dedupeWatched([for (final l in lists) ...l]);
    },
  );
});

/// 继续观看 / 观看记录去重：单集按"剧名 + 季 + 集"，电影按作品键；保留先出现的（更近的）
List<MediaItem> dedupeWatched(Iterable<MediaItem> items) {
  final seen = <String>{};
  final out = <MediaItem>[];
  for (final it in items) {
    final key = it.kind == MediaKind.episode ? 'ep:${it.seriesName ?? it.seriesId}' : titleKeyOf(it);
    if (seen.add(key)) out.add(it);
  }
  return out;
}

class FavoritesPage extends ConsumerWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(favoritesProvider);
    return _CollectionScaffold(
      title: '收藏',
      itemWidth: PosterCard.width,
      subtitle: async.value == null ? '加载中…' : '${async.value!.length} 部作品',
      empty: async.hasValue && async.value!.isEmpty ? '还没有收藏：在详情页按 ♡ 收藏' : null,
      itemCount: async.value?.length ?? 0,
      itemBuilder: (context, i) {
        final g = async.value![i];
        return _PosterTile(key: ValueKey('${g.primary.serverId}/${g.primary.id}'), title: g);
      },
    );
  }
}

class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resume = dedupeWatched(ref.watch(resumeProvider).value ?? const []);
    final played = ref.watch(recentlyPlayedProvider).value ?? const <MediaItem>[];
    final names = {for (final s in ref.watch(configProvider).servers) s.id: s.displayName};
    final all = [...resume, ...played];
    return _CollectionScaffold(
      title: '观看记录',
      itemWidth: LandscapeCard.width,
      subtitle: '继续观看 ${resume.length} · 最近看过 ${played.length}',
      empty: resume.isEmpty && played.isEmpty ? '还没有观看记录' : null,
      itemCount: all.length,
      itemBuilder: (context, i) {
        final it = all[i];
        return _LandscapeTile(key: ValueKey('${it.serverId}/${it.id}'), item: it, server: names[it.serverId]);
      },
    );
  }
}

class _CollectionScaffold extends StatelessWidget {
  const _CollectionScaffold({
    required this.title,
    required this.subtitle,
    required this.itemCount,
    required this.itemBuilder,
    required this.itemWidth,
    this.empty,
  });

  /// 卡片设计宽度（网格按它铺满整行）
  final double itemWidth;
  final String title;
  final String subtitle;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final String? empty;

  @override
  Widget build(BuildContext context) {
    // 懒加载网格：只建屏幕附近的几行（收藏可能有几百部，一次全建会卡住）；电视上多预建一些，方向键往下时下一行已经在
    return FocusAutoScroll(
      child: CustomScrollView(
        scrollCacheExtent: ScrollCacheExtent.pixels(PlatformProfile.isTv ? 800 : 400),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(VSpace.contentLeft, VSpace.safeV, VSpace.safeH, 0),
            sliver: SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 40),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(title, style: VText.h1),
                    const SizedBox(width: 20),
                    Text(subtitle, style: VText.caption.copyWith(color: VColors.textTertiary)),
                  ],
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(VSpace.contentLeft, 0, VSpace.safeH, 200),
            sliver: empty != null
                ? SliverToBoxAdapter(
                    child: Text(empty!, style: VText.label.copyWith(color: VColors.textTertiary)),
                  )
                : SliverFillGrid(itemWidth: itemWidth, itemCount: itemCount, itemBuilder: itemBuilder),
          ),
        ],
      ),
    );
  }
}

class _PosterTile extends StatefulWidget {
  const _PosterTile({super.key, required this.title});

  final AggregatedTitle title;

  @override
  State<_PosterTile> createState() => _PosterTileState();
}

class _PosterTileState extends State<_PosterTile> {
  final _node = FocusNode(debugLabel: 'favorite');

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(width: PosterCard.width, child: mediaPosterCard(context, widget.title.primary, _node));
}

class _LandscapeTile extends StatefulWidget {
  const _LandscapeTile({super.key, required this.item, this.server});

  final MediaItem item;
  final String? server;

  @override
  State<_LandscapeTile> createState() => _LandscapeTileState();
}

class _LandscapeTileState extends State<_LandscapeTile> {
  final _node = FocusNode(debugLabel: 'history');

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: LandscapeCard.width,
    child: mediaLandscapeCard(
      context,
      widget.item,
      _node,
      watchedOn: widget.server ?? '未知服务器',
      onMenu: () => openMediaItem(context, widget.item),
    ),
  );
}
