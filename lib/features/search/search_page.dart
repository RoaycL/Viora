import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/widgets/fill_grid.dart';

import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../../data/config/config_store.dart';
import '../../data/index/index_sync.dart';
import '../../data/index/media_index.dart';
import '../../data/media/media_models.dart';
import '../../data/media/server_registry.dart';
import '../../data/tmdb/tmdb_client.dart';
import '../../ui/focus/focus_auto_scroll.dart';
import '../../ui/focus/focusable.dart';
import '../../ui/rows/cards.dart';
import '../../ui/widgets/form.dart';
import '../../ui/widgets/server_image.dart';
import '../browse/media_cards.dart';

/// 聚合搜索（docs/04-aggregation.md §4）：
/// 本地索引立即出结果（支持拼音首字母 / 全拼），再并发查各服务器补齐，同一部作品合并显示资源数。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.initialQuery = ''});

  /// 从详情页"在媒体库中搜索"进来时预填
  final String initialQuery;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _query = TextEditingController();
  Timer? _debounce;
  int _generation = 0;
  List<AggregatedTitle> _results = const [];
  bool _searchingRemote = false;
  int _pendingServers = 0;

  @override
  void initState() {
    super.initState();
    _query.text = widget.initialQuery;
    _query.addListener(_onChanged);
    if (widget.initialQuery.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _search);
    setState(() {});
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    final gen = ++_generation;
    if (q.isEmpty) {
      setState(() => _results = const []);
      return;
    }
    // 1. 本地索引
    final index = await ref.read(mediaIndexProvider.future);
    final config = ref.read(configProvider);
    final local = [
      for (final it in index?.search(q) ?? const <MediaItem>[])
        if (itemVisible(config, it)) it,
    ];
    if (gen != _generation || !mounted) return;
    var groups = groupTitles(local);
    setState(() {
      _results = groups;
      _searchingRemote = true;
    });

    // 2. 各服务器实时搜索（单台 5 秒超时），回来一台合并一台
    final servers = ref.read(configProvider).servers.toList();
    setState(() => _pendingServers = servers.length);
    await Future.wait(
      servers.map((s) async {
        final client = ref.read(serverClientProvider(s.id));
        try {
          final page = await client!.items(searchTerm: q, limit: 40).timeout(const Duration(seconds: 5));
          if (gen != _generation || !mounted) return;
          groups = groupTitles([for (final g in groups) ...g.copies, ...page.items]);
          setState(() => _results = groups);
        } catch (_) {
        } finally {
          if (gen == _generation && mounted) setState(() => _pendingServers--);
        }
      }),
    );
    if (gen == _generation && mounted) setState(() => _searchingRemote = false);
  }

  void _type(String s) {
    _query.text = '${_query.text}$s';
    _query.selection = TextSelection.collapsed(offset: _query.text.length);
  }

  void _backspace() {
    final t = _query.text;
    if (t.isEmpty) return;
    _query.text = t.characters.skipLast(1).toString();
  }

  @override
  Widget build(BuildContext context) {
    final hasQuery = _query.text.trim().isNotEmpty;
    return FocusAutoScroll(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(VSpace.contentLeft, VSpace.safeV, 0, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 左：输入
            SizedBox(
              width: 560,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('搜索', style: VText.h1),
                  const SizedBox(height: 32),
                  VTextField(
                    label: PlatformProfile.isTv ? '片名 / 拼音首字母（如 sgdlr）' : '片名 / 拼音首字母 / 全拼',
                    controller: _query,
                    autofocus: true,
                    hint: '时光代理人',
                  ),
                  if (PlatformProfile.isTv) ...[
                    const SizedBox(height: 24),
                    _Keyboard(onKey: _type, onBackspace: _backspace, onClear: () => _query.clear()),
                  ],
                  const SizedBox(height: 20),
                  Text(
                    _searchingRemote && _pendingServers > 0
                        ? '本地索引已返回，正在查询 $_pendingServers 台服务器…'
                        : hasQuery
                        ? '共 ${_results.length} 部作品'
                        : '同时搜索所有服务器，同一部作品会合并显示',
                    style: VText.small.copyWith(color: VColors.textTertiary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 56),
            // 右：结果
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(right: VSpace.safeH, top: 110, bottom: 200),
                child: hasQuery && _results.isEmpty && !_searchingRemote
                    ? Text('没有找到相关内容', style: VText.label.copyWith(color: VColors.textTertiary))
                    : FillGrid(
                        itemWidth: PosterCard.width,
                        children: [
                          for (final g in _results)
                            _ResultCard(key: ValueKey('${g.primary.serverId}/${g.primary.id}'), title: g),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends ConsumerStatefulWidget {
  const _ResultCard({super.key, required this.title});

  final AggregatedTitle title;

  @override
  ConsumerState<_ResultCard> createState() => _ResultCardState();
}

class _ResultCardState extends ConsumerState<_ResultCard> {
  final _node = FocusNode(debugLabel: 'search-result');

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    final item = title.primary;
    return SizedBox(
      width: PosterCard.width,
      child: PosterCard(
        node: _node,
        art: placeholderArt(item.id),
        image: ServerImage(serverId: item.serverId, image: item.primary, fallbackSeed: item.id),
        title: localizedMeta(ref, item).title,
        subtitle: [if (item.year != null) '${item.year}', item.kind == MediaKind.series ? '剧集' : '电影'].join(' · '),
        resources: title.copies.length,
        onActivate: () => openMediaItem(context, item),
      ),
    );
  }
}

/// TV 屏幕键盘：字母数字（配合拼音首字母搜索），以及空格 / 删除 / 清空
class _Keyboard extends StatelessWidget {
  const _Keyboard({required this.onKey, required this.onBackspace, required this.onClear});

  final ValueChanged<String> onKey;
  final VoidCallback onBackspace;
  final VoidCallback onClear;

  static const _keys = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890';

  @override
  Widget build(BuildContext context) {
    Widget key(String label, VoidCallback onTap, {double width = 80}) => VFocusable(
      radius: VRadius.md,
      scale: 1.08,
      showRing: false,
      onActivate: onTap,
      builder: (context, focused) => AnimatedContainer(
        duration: VMotion.focus,
        width: width,
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: focused ? Colors.white : const Color(0x0FFFFFFF),
          borderRadius: BorderRadius.circular(VRadius.md),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            color: focused ? const Color(0xFF0B0C10) : Colors.white,
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [for (final c in _keys.split('')) key(c, () => onKey(c.toLowerCase()))],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            key('空格', () => onKey(' '), width: 170),
            const SizedBox(width: 10),
            key('删除', onBackspace, width: 170),
            const SizedBox(width: 10),
            key('清空', onClear, width: 170),
          ],
        ),
      ],
    );
  }
}
