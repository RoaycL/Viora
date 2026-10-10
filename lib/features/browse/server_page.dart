import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/config/config_store.dart';
import '../../data/media/media_models.dart';
import '../../data/media/server_registry.dart';
import '../../ui/focus/focusable.dart';
import '../../ui/focus/row_focus.dart';
import '../../ui/rows/cards.dart';
import '../../ui/rows/focus_row.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/server_image.dart';
import 'media_cards.dart';
import '../../ui/focus/input_mode.dart';

final _serverResumeProvider = FutureProvider.family<List<MediaItem>, String>((ref, serverId) async {
  final client = ref.watch(serverClientProvider(serverId));
  return client == null ? const [] : client.resume(limit: 16);
});

/// 单台服务器的首页：继续观看、媒体库、各媒体库最新。
class ServerPage extends ConsumerWidget {
  const ServerPage({super.key, required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(configProvider.select((c) => c.server(serverId)));
    if (server == null) return const Center(child: Text('服务器不存在', style: VText.h2));
    final libraries = ref.watch(librariesProvider(serverId));
    final resume = ref.watch(_serverResumeProvider(serverId)).value ?? const <MediaItem>[];

    return RowFocusScope(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(top: VSpace.safeV, bottom: 400),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: VSpace.contentLeft, bottom: 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(server.name, style: VText.h1),
                  const SizedBox(width: 20),
                  Text(server.type.label, style: VText.caption.copyWith(color: VColors.textTertiary)),
                ],
              ),
            ),
            switch (libraries) {
              AsyncError(:final error) => _ErrorBox(
                message: error.toString(),
                onRetry: () => ref.invalidate(librariesProvider(serverId)),
              ),
              AsyncData(value: final libs) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const RowAutoFocus(),
                  if (resume.isNotEmpty)
                    FocusRow(
                      rowIndex: 0,
                      title: '继续观看',
                      itemCount: resume.length,
                      itemExtent: LandscapeCard.width,
                      height: LandscapeCard.height,
                      itemBuilder: (context, i, node) => mediaLandscapeCard(context, resume[i], node),
                    ),
                  FocusRow(
                    rowIndex: 1,
                    title: '媒体库',
                    itemCount: libs.length,
                    itemExtent: 400,
                    height: 225,
                    itemBuilder: (context, i, node) => _LibraryCard(serverId: serverId, library: libs[i], node: node),
                  ),
                  for (var i = 0; i < libs.length; i++)
                    _LatestRow(rowIndex: 2 + i, serverId: serverId, library: libs[i]),
                ],
              ),
              _ => const Padding(
                padding: EdgeInsets.only(left: VSpace.contentLeft, top: 40),
                child: Text('正在加载媒体库…', style: VText.label),
              ),
            },
          ],
        ),
      ),
    );
  }
}

class _LibraryCard extends StatelessWidget {
  const _LibraryCard({required this.serverId, required this.library, required this.node});

  final String serverId;
  final Library library;
  final FocusNode node;

  @override
  Widget build(BuildContext context) {
    return VFocusable(
      focusNode: node,
      onActivate: () =>
          context.go('/library/server/$serverId/lib/${library.id}?name=${Uri.encodeComponent(library.name)}'),
      builder: (context, focused) => ClipRRect(
        borderRadius: BorderRadius.circular(VRadius.card),
        child: SizedBox(
          width: 400,
          height: 225,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ServerImage(serverId: serverId, image: library.image, width: 400, fallbackSeed: library.id),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0xB3000000)],
                  ),
                ),
              ),
              // 服务器生成的媒体库封面通常已带名称，只在没有封面时显示文字
              if (library.image == null)
                Positioned(
                  left: 20,
                  bottom: 16,
                  child: Text(library.name, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LatestRow extends ConsumerWidget {
  const _LatestRow({required this.rowIndex, required this.serverId, required this.library});

  final int rowIndex;
  final String serverId;
  final Library library;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(latestProvider((serverId: serverId, libraryId: library.id))).value;
    if (items == null || items.isEmpty) return const SizedBox.shrink();
    return FocusRow(
      rowIndex: rowIndex,
      title: '最新 · ${library.name}',
      itemCount: items.length,
      itemExtent: PosterCard.width,
      height: PosterCard.height,
      itemBuilder: (context, i, node) => mediaPosterCard(context, items[i], node),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: VSpace.contentLeft, top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: VText.label.copyWith(color: VColors.bad)),
          const SizedBox(height: 24),
          PillButton(autofocus: true, icon: Icons.refresh_rounded, label: '重试', onPressed: onRetry),
        ],
      ),
    );
  }
}

/// 某个媒体库的全部内容（海报网格，滚动到底自动加载下一页）。
class LibraryGridPage extends ConsumerStatefulWidget {
  const LibraryGridPage({super.key, required this.serverId, required this.libraryId, required this.title});

  final String serverId;
  final String libraryId;
  final String title;

  @override
  ConsumerState<LibraryGridPage> createState() => _LibraryGridPageState();
}

class _LibraryGridPageState extends ConsumerState<LibraryGridPage> {
  static const _pageSize = 60;
  final _items = <MediaItem>[];
  int _total = -1;
  bool _loading = false;
  String? _error;
  String _sort = 'DateCreated,SortName';

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || (_total >= 0 && _items.length >= _total)) return;
    setState(() => _loading = true);
    try {
      final client = ref.read(serverClientProvider(widget.serverId));
      if (client == null) throw StateError('服务器不存在');
      final page = await client.items(
        parentId: widget.libraryId,
        start: _items.length,
        limit: _pageSize,
        sortBy: _sort,
        sortOrder: _sort.startsWith('SortName') ? 'Ascending' : 'Descending',
      );
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setSort(String sort) {
    if (sort == _sort) return;
    setState(() {
      _sort = sort;
      _items.clear();
      _total = -1;
    });
    _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    // 按画布宽度算列数（Windows 画布更宽，列数更多），卡片等比放大铺满每一格
    final columns =
        ((MediaQuery.sizeOf(context).width - VSpace.contentLeft - VSpace.safeH + 24) / (PosterCard.width + 24))
            .floor()
            .clamp(3, 12);
    return CustomScrollView(
      scrollCacheExtent: const ScrollCacheExtent.pixels(1400),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(VSpace.contentLeft, VSpace.safeV, VSpace.safeH, 24),
          sliver: SliverToBoxAdapter(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(widget.title, style: VText.h1, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 20),
                if (_total >= 0) Text('$_total 部', style: VText.caption.copyWith(color: VColors.textTertiary)),
                const Spacer(),
                for (final (key, label) in const [
                  ('DateCreated,SortName', '最近添加'),
                  ('SortName', '名称'),
                  ('PremiereDate,SortName', '上映时间'),
                  ('CommunityRating,SortName', '评分'),
                ]) ...[
                  _SortChip(label: label, selected: _sort == key, onTap: () => _setSort(key)),
                  const SizedBox(width: 12),
                ],
              ],
            ),
          ),
        ),
        if (_error != null && _items.isEmpty)
          SliverToBoxAdapter(
            child: _ErrorBox(message: _error!, onRetry: _loadMore),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(VSpace.contentLeft, 12, VSpace.safeH, 200),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 32,
              crossAxisSpacing: 24,
              childAspectRatio: PosterCard.width / PosterCard.height,
            ),
            itemCount: _items.length,
            itemBuilder: (context, i) {
              if (i >= _items.length - columns * 2) WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
              return FittedBox(
                fit: BoxFit.fitWidth,
                alignment: Alignment.topLeft,
                child: _GridPoster(item: _items[i], autofocus: i == 0),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _GridPoster extends StatefulWidget {
  const _GridPoster({required this.item, this.autofocus = false});

  final MediaItem item;
  final bool autofocus;

  @override
  State<_GridPoster> createState() => _GridPosterState();
}

class _GridPosterState extends State<_GridPoster> {
  final _node = FocusNode(debugLabel: 'grid');

  @override
  void initState() {
    super.initState();
    _node.addListener(() {
      if (_node.hasPrimaryFocus && InputMode.shouldAutoScroll) {
        Scrollable.ensureVisible(context, alignment: 0.4, duration: VMotion.scroll, curve: Curves.easeOutCubic);
      }
    });
    if (widget.autofocus) WidgetsBinding.instance.addPostFrameCallback((_) => _node.requestFocus());
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.contain,
    alignment: Alignment.topCenter,
    child: SizedBox(
      width: PosterCard.width,
      height: PosterCard.height,
      child: mediaPosterCard(context, widget.item, _node),
    ),
  );
}

class _SortChip extends StatelessWidget {
  const _SortChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return VFocusable(
      radius: 999,
      scale: 1.05,
      showRing: false,
      onActivate: onTap,
      builder: (context, focused) => AnimatedContainer(
        duration: VMotion.focus,
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: focused ? Colors.white : (selected ? const Color(0x33FFFFFF) : const Color(0x0DFFFFFF)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: VText.caption.copyWith(
            color: focused ? const Color(0xFF0B0C10) : Colors.white,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
