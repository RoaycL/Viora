import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ui/widgets/fill_grid.dart';

import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../../core/log/load_metrics.dart';
import '../../core/voice/voice_input.dart';
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
  /// 最多显示的作品数（结果网格是懒加载的，这里只是不让一次合并、排序的数据太多）
  static const maxResults = 120;

  final _query = TextEditingController();
  int _generation = 0;

  /// 上一次点「搜索」时的关键字（结果对应的就是它）
  String _searched = '';

  /// Windows：结果按类型筛选、最近搜索、输入框焦点（输入框高亮）
  _Kind _kind = _Kind.all;
  List<String> _recent = const [];
  final _fieldFocus = FocusNode(debugLabel: 'search-field');
  static const _recentKey = 'viora.search.recent';
  static const _recentMax = 10;
  List<AggregatedTitle> _results = const [];
  bool _searchingRemote = false;
  int _pendingServers = 0;

  /// 电视：系统有语音识别时屏幕键盘多一个「语音」键
  bool _voice = false;

  @override
  void initState() {
    super.initState();
    _fieldFocus.addListener(() => setState(() {}));
    _loadRecent();
    if (PlatformProfile.isTv) {
      VoiceInput.available().then((v) {
        if (mounted && v) setState(() => _voice = true);
      });
    }
    _query.text = widget.initialQuery;
    _query.addListener(_onChanged);
    if (widget.initialQuery.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _query.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  /// 语音输入：说出片名，识别出来后直接搜索（去掉识别结果末尾的标点）
  Future<void> _voiceSearch() async {
    final text = await VoiceInput.recognize(prompt: '说出片名');
    if (!mounted || text == null) return;
    final q = text.replaceAll(RegExp(r'[。．.，,！!？?\s]+$'), '').trim();
    if (q.isEmpty) return;
    _query.text = q;
    _query.selection = TextSelection.collapsed(offset: q.length);
    _search();
  }

  Future<void> _loadRecent() async {
    try {
      final list = (await SharedPreferences.getInstance()).getStringList(_recentKey) ?? const [];
      if (mounted) setState(() => _recent = list);
    } catch (_) {}
  }

  Future<void> _remember(String q) async {
    final list = [q, ..._recent.where((r) => r != q)].take(_recentMax).toList();
    setState(() => _recent = list);
    try {
      await (await SharedPreferences.getInstance()).setStringList(_recentKey, list);
    } catch (_) {}
  }

  Future<void> _clearRecent() async {
    setState(() => _recent = const []);
    try {
      await (await SharedPreferences.getInstance()).remove(_recentKey);
    } catch (_) {}
  }

  void _setKind(_Kind k) => setState(() => _kind = k);

  void _searchFor(String q) {
    _query.text = q;
    _query.selection = TextSelection.collapsed(offset: q.length);
    _search();
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
    _kind = _Kind.all;
    if (q.isEmpty) {
      setState(() => _results = const []);
      return;
    }
    if (PlatformProfile.isDesktop) unawaited(_remember(q));
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
    final offline = ref.read(serverReachabilityProvider);
    final servers = config.servers.where((s) => offline[s.id] != config.clientKey(s.id)).toList();
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

    // 3. 经 TMDB 换名：输入外文名 / 译名 / 别名时，本地索引和服务器都按片名匹配不上，
    //    先在 TMDB 找到是哪部作品，再按 TMDB ID 从本地索引里取出片库里的条目
    final tmdb = ref.read(tmdbClientProvider);
    Future<void> viaTmdb() async {
      if (tmdb == null || index == null) return;
      try {
        final titles = await tmdb.search(q).timeout(const Duration(seconds: 5));
        if (gen != _generation || !mounted) return;
        var added = 0;
        final seen = {for (final it in all) '${it.serverId}/${it.id}'};
        for (final t in titles.take(10)) {
          for (final it in index.byTmdb(t.kind, '${t.id}')) {
            if (itemVisible(config, it) && seen.add('${it.serverId}/${it.id}')) {
              all.add(it);
              added++;
            }
          }
        }
        trace.event('tmdb', count: added);
        if (added > 0) scheduleRegroup();
      } catch (_) {}
    }

    await Future.wait([
      viaTmdb(),
      ...servers.map((s) async {
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
        } catch (e) {
          if (mounted && client != null) {
            ref.read(serverReachabilityProvider.notifier).reportAggregateFailure(client, e);
          }
        } finally {
          if (gen == _generation && mounted) setState(() => _pendingServers--);
        }
      }),
    ]);
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
    if (PlatformProfile.isDesktop) return _desktop(context, typed, hasQuery);
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
                    _Keyboard(
                      onKey: _type,
                      onBackspace: _backspace,
                      onClear: () => _query.clear(),
                      onSearch: _search,
                      onVoice: _voice ? _voiceSearch : null,
                    ),
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
            // 懒加载：只建屏幕附近的几行。结果最多上百部，一次全建的话每张卡片都同时去下载海报、
            // 向 TMDB 补中文标题，电视上内存和 CPU 一下子顶满（搜索后闪退）
            Expanded(
              child: CustomScrollView(
                scrollCacheExtent: ScrollCacheExtent.pixels(PlatformProfile.isTv ? 800 : 400),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.only(right: VSpace.safeH, top: 110, bottom: 200),
                    sliver: hasQuery && _results.isEmpty && !_searchingRemote
                        ? SliverToBoxAdapter(
                            child: Text('没有找到相关内容', style: VText.label.copyWith(color: VColors.textTertiary)),
                          )
                        : SliverFillGrid(
                            itemWidth: PosterCard.width,
                            itemCount: _results.length,
                            itemBuilder: (context, i) {
                              final g = _results[i];
                              return _ResultCard(key: ValueKey('${g.primary.serverId}/${g.primary.id}'), title: g);
                            },
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _Kind {
  all('全部'),
  movie('电影'),
  series('剧集');

  const _Kind(this.label);
  final String label;

  bool matches(MediaItem it) => switch (this) {
    _Kind.all => true,
    _Kind.series => it.kind == MediaKind.series || it.kind == MediaKind.episode,
    _Kind.movie => it.kind != MediaKind.series && it.kind != MediaKind.episode,
  };
}

extension on _SearchPageState {
  /// Windows 搜索页：顶部一条大搜索框；没搜的时候显示最近搜索；结果铺满整个宽度，可以按类型筛选
  Widget _desktop(BuildContext context, String typed, bool hasQuery) {
    final shown = [
      for (final g in _results)
        if (_kind.matches(g.primary)) g,
    ];
    final status = _searchingRemote && _pendingServers > 0
        ? '正在查询 $_pendingServers 台服务器…'
        : typed.isNotEmpty && typed != _searched
        ? '按回车开始搜索'
        : null;
    return FocusAutoScroll(
      child: CustomScrollView(
        scrollCacheExtent: const ScrollCacheExtent.pixels(400),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(VSpace.contentLeft, VSpace.pageTop, VSpace.safeH, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 搜索框居中（和下面「想看什么」「没有找到」的提示对齐）
                  Center(
                    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1100), child: _bar(typed)),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      status ?? '片名、拼音首字母（如 sgdlr）或全拼都可以 · 同时搜索所有服务器，同一部作品合并显示',
                      style: VText.small.copyWith(color: VColors.textTertiary),
                    ),
                  ),
                  if (hasQuery && _results.isNotEmpty) ...[
                    const SizedBox(height: 40),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text('「$_searched」', style: VText.rowTitle),
                        const SizedBox(width: 12),
                        Text('${_results.length} 部作品', style: VText.label.copyWith(color: VColors.textTertiary)),
                        if (_searchingRemote) ...[
                          const SizedBox(width: 14),
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: VColors.textTertiary),
                          ),
                        ],
                        const Spacer(),
                        for (final k in _Kind.values) ...[
                          const SizedBox(width: 10),
                          _FilterChip(
                            label: '${k.label} ${_results.where((g) => k.matches(g.primary)).length}',
                            selected: _kind == k,
                            onTap: () => _setKind(k),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],
                ],
              ),
            ),
          ),
          if (!hasQuery)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(VSpace.contentLeft, 56, VSpace.safeH, 120),
              sliver: SliverToBoxAdapter(child: _idle()),
            )
          else if (_results.isEmpty)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(VSpace.contentLeft, 96, VSpace.safeH, 120),
              sliver: SliverToBoxAdapter(
                child: _Hint(
                  icon: _searchingRemote ? Icons.travel_explore_rounded : Icons.search_off_rounded,
                  title: _searchingRemote ? '正在各服务器上查找「$_searched」…' : '没有找到「$_searched」',
                  subtitle: _searchingRemote ? '本地索引里没有，稍等服务器返回' : '换个关键词试试，或者用拼音首字母（如 sgdlr）',
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(VSpace.contentLeft, 0, VSpace.safeH, 160),
              sliver: SliverFillGrid(
                itemWidth: PosterCard.width,
                itemCount: shown.length,
                itemBuilder: (context, i) {
                  final g = shown[i];
                  return _ResultCard(key: ValueKey('${g.primary.serverId}/${g.primary.id}'), title: g);
                },
              ),
            ),
        ],
      ),
    );
  }

  /// 大搜索框：左边放大镜，右边清空和「搜索」
  Widget _bar(String typed) {
    final focused = _fieldFocus.hasFocus;
    return AnimatedContainer(
      duration: VMotion.duration(context, VMotion.focus),
      height: 76,
      padding: const EdgeInsets.only(left: 28, right: 10),
      decoration: BoxDecoration(
        color: focused ? const Color(0x1FFFFFFF) : const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: focused ? const Color(0x80FFFFFF) : const Color(0x1FFFFFFF), width: 1.5),
        boxShadow: focused ? const [BoxShadow(color: Color(0x40000000), blurRadius: 30, offset: Offset(0, 10))] : null,
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 32, color: focused ? Colors.white : VColors.textTertiary),
          const SizedBox(width: 18),
          Expanded(
            child: TextField(
              controller: _query,
              focusNode: _fieldFocus,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              cursorColor: Colors.white,
              style: const TextStyle(fontSize: 26, color: Colors.white),
              decoration: InputDecoration(
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: '搜索电影、剧集',
                hintStyle: TextStyle(fontSize: 26, color: VColors.textTertiary.withValues(alpha: 0.8)),
              ),
            ),
          ),
          if (typed.isNotEmpty)
            IconButton(
              tooltip: '清空',
              onPressed: () {
                _query.clear();
                _fieldFocus.requestFocus();
              },
              icon: const Icon(Icons.close_rounded, size: 26, color: VColors.textTertiary),
            ),
          const SizedBox(width: 8),
          PillButton(label: '搜索', onPressed: typed.isEmpty ? null : _search),
        ],
      ),
    );
  }

  /// 还没搜索：最近搜索（点一下直接搜），没有记录时一句提示
  Widget _idle() {
    if (_recent.isEmpty) {
      return const _Hint(
        icon: Icons.manage_search_rounded,
        title: '想看什么？',
        subtitle: '输入片名，在所有服务器里一起找；同一部作品在几台服务器上都有，会合并成一张卡片',
      );
    }
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('最近搜索', style: VText.rowTitle.copyWith(fontSize: 24)),
            const SizedBox(width: 16),
            TextButton(
              onPressed: _clearRecent,
              child: Text('清除', style: VText.small.copyWith(color: VColors.textTertiary)),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final r in _recent)
              _FilterChip(label: r, icon: Icons.history_rounded, selected: false, onTap: () => _searchFor(r)),
          ],
        ),
      ],
    );
  }
}

/// 胶囊小按钮（筛选、最近搜索）
class _FilterChip extends StatefulWidget {
  const _FilterChip({required this.label, required this.selected, required this.onTap, this.icon});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  State<_FilterChip> createState() => _FilterChipState();
}

class _FilterChipState extends State<_FilterChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.selected;
    final fg = on ? VColors.background : (_hover ? Colors.white : const Color(0xCCFFFFFF));
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: VMotion.duration(context, VMotion.focus),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          decoration: BoxDecoration(
            color: on
                ? Colors.white
                : _hover
                ? const Color(0x29FFFFFF)
                : const Color(0x14FFFFFF),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: on ? Colors.white : const Color(0x1FFFFFFF)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[Icon(widget.icon, size: 18, color: fg), const SizedBox(width: 8)],
              Text(
                widget.label,
                style: TextStyle(fontSize: 18, color: fg, fontWeight: on ? FontWeight.w600 : null),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 空状态：一个大图标、一行标题、一行说明
class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x0FFFFFFF)),
              child: Icon(icon, size: 56, color: VColors.textTertiary),
            ),
            const SizedBox(height: 28),
            Text(title, style: VText.h2.copyWith(fontSize: 30), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(
              subtitle,
              style: VText.label.copyWith(color: VColors.textTertiary, height: 1.6),
              textAlign: TextAlign.center,
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
  const _Keyboard({
    required this.onKey,
    required this.onBackspace,
    required this.onClear,
    required this.onSearch,
    this.onVoice,
  });

  final ValueChanged<String> onKey;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback onSearch;

  /// 语音输入；null = 系统没有语音识别，不显示这个键
  final VoidCallback? onVoice;

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
          children: [
            for (final c in _keys.split('')) key(c, () => onKey(c.toLowerCase())),
            // 语音键接在数字后面（同一行还有空位）
            if (onVoice case final voice?) key('语音', voice, width: 170),
          ],
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
