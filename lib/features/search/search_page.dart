import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/widgets/fill_grid.dart';

import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../../core/log/load_metrics.dart';
import '../../data/cache/account_scope.dart';
import '../../data/config/config_store.dart';
import '../../data/index/index_sync.dart';
import '../../data/index/media_index.dart';
import '../../data/media/media_models.dart';
import '../../data/media/server_registry.dart';
import '../../data/tmdb/tmdb_client.dart';
import '../../ui/focus/focus_auto_scroll.dart';
import '../../ui/focus/focusable.dart';
import '../../ui/rows/cards.dart';
import '../../ui/widgets/buttons.dart';
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
  /// 最多显示的作品数：结果网格不是懒加载，几百张海报一起构建、下载会拖垮电视
  static const maxResults = 120;

  final _query = TextEditingController();
  int _generation = 0;

  /// 上一次点「搜索」时的关键字（结果对应的就是它）
  String _searched = '';
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
    _query.dispose();
    super.dispose();
  }

  /// 输入时不搜索（电视上每输一个字就查一遍会很卡），点「搜索」/ 按回车才开始；清空时清掉结果
  void _onChanged() {
    if (_query.text.trim().isEmpty && _searched.isNotEmpty) {
      _generation++;
      _searched = '';
      _results = const [];
      _searchingRemote = false;
      _pendingServers = 0;
    }
    setState(() {});
  }

  Future<void> _search() async {
    final trace = LoadTrace('search');
    final q = _query.text.trim();
    final gen = ++_generation;
    _searched = q;
    if (q.isEmpty) {
      setState(() => _results = const []);
      return;
    }
    // 1. 本地索引（一个字母能匹配上万条，只取前 100 条）
    final index = await ref.read(mediaIndexProvider.future);
    if (gen != _generation || !mounted) return;
    final config = ref.read(configProvider);
    final localTrace = LoadTrace('search_local');
    final local = [
      for (final it in index?.search(q, limit: 100) ?? const <MediaItem>[])
        if (itemVisible(config, it)) it,
    ];
    localTrace.event('complete', count: local.length);
    if (gen != _generation || !mounted) return;
    final all = [...local];
    setState(() {
      _results = groupTitles(all).take(maxResults).toList();
      _searchingRemote = false;
      _pendingServers = 0;
    });
    trace.event('local_ready', count: _results.length);

    // 2. 各服务器实时搜索：只有一个字母时不查（结果太多也没意义，16 台服务器一起查会把电视卡死）
    if (q.characters.length < 2) return;
    final servers = ref.read(configProvider).servers.toList();
    setState(() {
      _searchingRemote = true;
      _pendingServers = servers.length;
    });
    // 服务器陆续返回：合并后重新分组，最多每 300 毫秒刷新一次界面
    Timer? regroup;
    var firstRemote = true;
    void scheduleRegroup() {
      regroup ??= Timer(const Duration(milliseconds: 300), () {
        regroup = null;
        if (gen != _generation || !mounted) return;
        setState(() => _results = groupTitles(all).take(maxResults).toList());
      });
    }

    await Future.wait(
      servers.map((s) async {
        final client = ref.read(serverClientProvider(s.id));
        try {
          final page = await client!.items(searchTerm: q, limit: 20).timeout(const Duration(seconds: 5));
          if (gen != _generation || !mounted) return;
          all.addAll(page.items);
          if (firstRemote) {
            firstRemote = false;
            trace.event('first_remote', count: page.items.length, sources: servers.length);
          }
          scheduleRegroup();
        } catch (_) {
        } finally {
          if (gen == _generation && mounted) setState(() => _pendingServers--);
        }
      }),
    );
    regroup?.cancel();
    if (gen == _generation && mounted) {
      setState(() => _results = groupTitles(all).take(maxResults).toList());
    }
    if (gen == _generation && mounted) setState(() => _searchingRemote = false);
    if (gen == _generation && mounted) trace.event('complete', count: _results.length, sources: servers.length);
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
    ref.listen(configProvider.select(mediaFeedScope), (_, _) {
      _generation++;
      setState(() {
        _results = const [];
        _searched = '';
        _searchingRemote = false;
        _pendingServers = 0;
      });
    });
    final typed = _query.text.trim();
    final hasQuery = _searched.isNotEmpty;
    final field = VTextField(
      label: PlatformProfile.isTv ? '片名 / 拼音首字母（如 sgdlr）' : '片名 / 拼音首字母 / 全拼',
      controller: _query,
      autofocus: true,
      hint: '时光代理人',
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _search(),
    );
    return FocusAutoScroll(
      child: Padding(
        padding: EdgeInsets.fromLTRB(VSpace.contentLeft, VSpace.pageTop, 0, 0),
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
                  if (PlatformProfile.isTv) ...[
                    // 电视：屏幕键盘最后一行有「搜索」键
                    field,
                    const SizedBox(height: 24),
                    _Keyboard(onKey: _type, onBackspace: _backspace, onClear: () => _query.clear(), onSearch: _search),
                  ] else
                    // Windows：输入框右边一个「搜索」按钮，也可以直接按回车
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(child: field),
                        const SizedBox(width: 16),
                        PillButton(label: '搜索', icon: Icons.search_rounded, onPressed: _search),
                      ],
                    ),
                  const SizedBox(height: 20),
                  Text(
                    _searchingRemote && _pendingServers > 0
                        ? '本地索引已返回，正在查询 $_pendingServers 台服务器…'
                        : typed.isNotEmpty && typed != _searched
                        ? (PlatformProfile.isTv ? '输入完成后按「搜索」' : '输入完成后按回车或点「搜索」')
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
  const _Keyboard({required this.onKey, required this.onBackspace, required this.onClear, required this.onSearch});

  final ValueChanged<String> onKey;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback onSearch;

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
            key('空格', () => onKey(' '), width: 125),
            const SizedBox(width: 10),
            key('删除', onBackspace, width: 125),
            const SizedBox(width: 10),
            key('清空', onClear, width: 125),
            const SizedBox(width: 10),
            key('搜索', onSearch, width: 125),
          ],
        ),
      ],
    );
  }
}
