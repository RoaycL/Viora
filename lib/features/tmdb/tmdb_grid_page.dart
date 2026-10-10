import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/tmdb/tmdb_client.dart';
import '../../ui/focus/focus_auto_scroll.dart';
import '../../ui/rows/cards.dart';
import '../../ui/widgets/tmdb_image.dart';
import 'tmdb_cards.dart';

/// 人物作品
class TmdbPersonPage extends ConsumerWidget {
  const TmdbPersonPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tmdbPersonProvider(id));
    final (person, credits) = async.value ?? (null, const <TmdbTitle>[]);
    return _TmdbGrid(
      loading: async.isLoading,
      error: async.hasError ? '加载失败：${async.error}' : null,
      header: person == null
          ? null
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipOval(
                  child: SizedBox(
                    width: 160,
                    height: 160,
                    child: TmdbImage(path: person.profilePath, size: 'w185', fallbackSeed: 'p$id'),
                  ),
                ),
                const SizedBox(width: 40),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(person.name, style: VText.h1),
                      const SizedBox(height: 8),
                      Text(
                        [?person.role, '${credits.length} 部作品'].join(' · '),
                        style: VText.caption.copyWith(color: VColors.textTertiary),
                      ),
                      if (person.biography?.isNotEmpty == true) ...[
                        const SizedBox(height: 16),
                        Text(
                          person.biography!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: VText.body.copyWith(color: VColors.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
      items: credits,
    );
  }
}

/// 播出平台的热门剧集
class TmdbNetworkPage extends ConsumerWidget {
  const TmdbNetworkPage({super.key, required this.id, required this.name});

  final int id;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tmdbNetworkProvider(id));
    final items = async.value ?? const <TmdbTitle>[];
    return _TmdbGrid(
      loading: async.isLoading,
      error: async.hasError ? '加载失败：${async.error}' : null,
      header: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(name, style: VText.h1),
          const SizedBox(width: 20),
          Text('热门剧集 · ${items.length} 部', style: VText.caption.copyWith(color: VColors.textTertiary)),
        ],
      ),
      items: items,
    );
  }
}

class _TmdbGrid extends StatelessWidget {
  const _TmdbGrid({required this.items, this.header, this.loading = false, this.error});

  final Widget? header;
  final List<TmdbTitle> items;
  final bool loading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: VColors.background,
      child: FocusAutoScroll(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(VSpace.safeH, 110, VSpace.safeH, 200),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ?header,
              const SizedBox(height: 40),
              if (error != null)
                Text(error!, style: VText.label.copyWith(color: VColors.bad))
              else if (loading && items.isEmpty)
                const Text('加载中…', style: VText.label)
              else
                Wrap(
                  spacing: 24,
                  runSpacing: 32,
                  children: [
                    for (var i = 0; i < items.length; i++)
                      _GridTile(key: ValueKey(items[i].key), title: items[i], autofocus: i == 0),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GridTile extends StatefulWidget {
  const _GridTile({super.key, required this.title, this.autofocus = false});

  final TmdbTitle title;
  final bool autofocus;

  @override
  State<_GridTile> createState() => _GridTileState();
}

class _GridTileState extends State<_GridTile> {
  final _node = FocusNode(debugLabel: 'tmdb-grid');

  @override
  void initState() {
    super.initState();
    if (widget.autofocus) WidgetsBinding.instance.addPostFrameCallback((_) => _node.requestFocus());
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: PosterCard.width,
    child: TmdbPosterCard(title: widget.title, node: _node),
  );
}
