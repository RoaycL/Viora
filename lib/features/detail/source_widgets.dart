import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/aggregate/sources.dart';
import '../../data/config/config_store.dart';
import '../../ui/widgets/brand_badges.dart';
import '../../ui/focus/focusable.dart';
import '../../ui/focus/row_focus.dart';
import '../../ui/rows/focus_row.dart';
import '../../ui/widgets/buttons.dart';
import '../library/library_page.dart' show ServerTypeLogo;

/// 版本的唯一标识（选中状态用）
String sourceKeyOf(SourceOption o) => '${o.serverId}/${o.item.id}/${o.source.id}';

/// 详情页「播放资源」区（媒体库详情页和 TMDB 详情页共用）：
/// - 查找中：显示占位卡片
/// - 找到后：4K / 1080P / 其他 分组、版本卡片（点一下选中，再点选中的那张直接播放）、「展开媒体信息」
/// - 没找到：显示 [emptyText]
///
/// 占用 [firstRow]、[firstRow] + 1、[firstRow] + 2 三行焦点。
class SourcesSection extends StatefulWidget {
  const SourcesSection({
    super.key,
    required this.options,
    required this.loading,
    required this.selected,
    required this.onSelect,
    required this.onPlay,
    required this.firstRow,
    this.caption,
    this.emptyText,
  });

  final List<SourceOption> options;
  final bool loading;

  /// 当前选中的版本（播放按钮播放它）
  final SourceOption? selected;
  final ValueChanged<SourceOption> onSelect;
  final ValueChanged<SourceOption> onPlay;
  final int firstRow;

  /// 标题旁的说明，如集号
  final String? caption;

  /// 没找到资源时的提示；为空时整个区域不显示
  final String? emptyText;

  static const rows = 3;

  @override
  State<SourcesSection> createState() => SourcesSectionState();
}

class SourcesSectionState extends State<SourcesSection> {
  String? _group;
  bool _expanded = false;
  final _infoKey = GlobalKey();
  int _revealGeneration = 0;

  /// 首屏快捷入口使用同一资源区，不重复查询或复制播放逻辑。
  Future<void> reveal() async {
    final generation = ++_revealGeneration;
    // 确认/鼠标激活刚请求的触发按钮焦点会在本轮微任务中提交。
    await Future<void>.value();
    if (!mounted || generation != _revealGeneration) return;
    final previousFocus = FocusManager.instance.primaryFocus;
    Scrollable.ensureVisible(context, alignment: .12, duration: VMotion.duration(context, VMotion.scroll));
    final controller = RowFocusScope.of(context);
    final options = widget.options;
    final rowIndex = options.isEmpty ? widget.firstRow : widget.firstRow + 1;
    final row = controller.rowAt(rowIndex);
    if (row == null || row.length == 0) return;
    // 切到当前选择所在的清晰度，再露出该版本。
    final selected = widget.selected ?? options.firstOrNull;
    if (selected != null && _group != selected.group) {
      setState(() => _group = selected.group);
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted || generation != _revealGeneration) return;
    final shown = options.where((o) => o.group == selected?.group).toList();
    final index = selected == null ? 0 : shown.indexWhere((o) => sourceKeyOf(o) == sourceKeyOf(selected));
    final target = controller.rowAt(rowIndex);
    if (target == null || target.length == 0) return;
    final node = target is RevealableFocusRow
        ? await target.revealNode(index.clamp(0, target.length - 1))
        : target.nodeAt(0);
    if (!mounted || generation != _revealGeneration || ModalRoute.of(context)?.isCurrent != true) return;
    if (FocusManager.instance.primaryFocus != previousFocus) return;
    node?.requestFocus();
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (!_expanded) return;
    // 展开后把媒体信息滚进视口（遥控器焦点还停在按钮上）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _infoKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      Scrollable.ensureVisible(
        ctx,
        duration: VMotion.duration(context, VMotion.scroll),
        curve: Curves.easeOutCubic,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final options = widget.options;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(VSpace.safeH, 0, VSpace.safeH, 18),
      child: Row(
        children: [
          Text('播放资源', style: VText.rowTitle.copyWith(color: const Color(0xEBFFFFFF))),
          if (widget.caption != null || options.isNotEmpty) ...[
            const SizedBox(width: 16),
            Text(
              [
                if (options.isNotEmpty) '${options.length} 个版本 · ${options.map((o) => o.serverId).toSet().length} 台服务器',
                ?widget.caption,
              ].join(' · '),
              style: VText.caption.copyWith(color: VColors.textTertiary),
            ),
          ],
        ],
      ),
    );

    if (options.isEmpty) {
      if (widget.loading) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [header, _status('正在查找播放资源'), const SourceSkeletonRow()],
        );
      }
      if (widget.emptyText == null) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          Padding(padding: const EdgeInsets.only(bottom: 32), child: _status(widget.emptyText!)),
        ],
      );
    }

    final selected = widget.selected ?? options.first;
    final selectedKey = sourceKeyOf(selected);
    final groups = [
      for (final g in const ['4K', '1080P', '其他'])
        if (options.any((o) => o.group == g)) g,
    ];
    final group = groups.contains(_group) ? _group! : selected.group;
    final shown = options.where((o) => o.group == group).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        Padding(
          padding: const EdgeInsets.only(left: VSpace.safeH),
          child: FocusButtonRow(
            rowIndex: widget.firstRow,
            spacing: 12,
            children: [
              for (final g in groups)
                (node) => SelectChip(
                  node: node,
                  label: '$g · ${options.where((o) => o.group == g).length}',
                  selected: g == group,
                  onTap: () => setState(() => _group = g),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        FocusRow(
          rowIndex: widget.firstRow + 1,
          leading: VSpace.safeH,
          itemCount: shown.length,
          itemExtent: SourceCard.width,
          height: SourceCard.height,
          itemBuilder: (context, i, node) {
            final o = shown[i];
            final isSelected = sourceKeyOf(o) == selectedKey;
            return SourceCard(
              node: node,
              option: o,
              selected: isSelected,
              onTap: () => isSelected ? widget.onPlay(o) : widget.onSelect(o),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(VSpace.safeH, 0, VSpace.safeH, 0),
          child: FocusButtonRow(
            rowIndex: widget.firstRow + 2,
            children: [
              (node) => PillButton(
                focusNode: node,
                icon: _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                label: _expanded ? '收起媒体信息' : '展开媒体信息',
                onPressed: _toggle,
              ),
            ],
          ),
        ),
        if (_expanded)
          Padding(
            key: _infoKey,
            padding: const EdgeInsets.fromLTRB(VSpace.safeH, 28, VSpace.safeH, 12),
            child: MediaInfoPanel(option: selected),
          ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _status(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: VSpace.safeH),
    child: FocusButtonRow(
      rowIndex: widget.firstRow,
      scrollable: true,
      children: [(node) => PillButton(focusNode: node, label: text)],
    ),
  );
}

/// 胶囊选择标签（季、清晰度分组）
class SelectChip extends StatelessWidget {
  const SelectChip({super.key, required this.node, required this.label, required this.selected, required this.onTap});

  final FocusNode node;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return VFocusable(
      focusNode: node,
      semanticLabel: label,
      selected: selected,
      radius: 999,
      scale: 1.05,
      showRing: false,
      onActivate: onTap,
      builder: (context, focused) => AnimatedContainer(
        duration: VMotion.duration(context, VMotion.focus),
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 26),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: focused ? Colors.white : (selected ? const Color(0x33FFFFFF) : const Color(0x0DFFFFFF)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: VText.label.copyWith(
            color: focused ? const Color(0xFF0B0C10) : Colors.white,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

String _gb(int bytes) =>
    bytes >= 1 << 30 ? '${(bytes / (1 << 30)).toStringAsFixed(2)} GB' : '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';

String _mbps(int bps) => '${(bps / 1000000).toStringAsFixed(bps >= 10000000 ? 1 : 2)} Mbps';

String _fps(double f) => '${f.toStringAsFixed(f % 1 == 0 ? 0 : 3)} fps';

String _channels(int c) => c >= 6 ? '${c - 1}.1' : '$c.0';

/// 版本卡片：动态范围 + 分辨率、大小与码率、编码，底部是所在服务器与延迟；选中时右上角打勾
class SourceCard extends ConsumerWidget {
  const SourceCard({super.key, required this.node, required this.option, required this.onTap, this.selected = false});

  static const width = 440.0;
  static const height = 220.0;

  final FocusNode node;
  final SourceOption option;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = ref.watch(configProvider.select((c) => c.server(option.serverId)?.type));
    final source = option.source;
    final v = source.video;
    final a = source.audio.where((s) => s.isDefault).firstOrNull ?? source.audio.firstOrNull;
    final specs = [
      ?v?.codec?.toUpperCase(),
      if (v?.bitDepth != null) '${v!.bitDepth}bit',
      if (v?.frameRate != null) _fps(v!.frameRate!),
      if (a != null) '${a.codec?.toUpperCase() ?? ''} ${a.channels == null ? '' : _channels(a.channels!)}'.trim(),
    ].join(' · ');
    final latency = option.latencyMs;
    return VFocusable(
      focusNode: node,
      selected: selected,
      radius: VRadius.card,
      scale: 1.05,
      onActivate: onTap,
      builder: (context, focused) => AnimatedContainer(
        duration: VMotion.duration(context, VMotion.focus),
        width: width,
        height: height,
        padding: const EdgeInsets.fromLTRB(24, 20, 20, 18),
        decoration: BoxDecoration(
          color: focused ? const Color(0x29FFFFFF) : const Color(0x12FFFFFF),
          borderRadius: BorderRadius.circular(VRadius.card),
          border: Border.all(
            color: selected ? const Color(0xB3FFFFFF) : const Color(0x1FFFFFFF),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Align(alignment: Alignment.centerLeft, child: VideoFormatBadges.of(source, height: 30)),
                ),
                if (selected)
                  const Icon(Icons.check_circle_rounded, size: 30, color: Colors.white)
                else
                  Text(
                    source.container.split(',').first.toUpperCase(),
                    style: VText.small.copyWith(color: VColors.textTertiary),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              [
                if (source.size != null) _gb(source.size!),
                if (source.bitrate != null) _mbps(source.bitrate!),
              ].join('   '),
              style: VText.caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            Text(
              specs,
              style: VText.small.copyWith(color: VColors.textTertiary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const Spacer(),
            Container(height: 1, color: const Color(0x1AFFFFFF)),
            const SizedBox(height: 12),
            Row(
              children: [
                if (type != null) ...[
                  SizedBox.square(dimension: 24, child: ServerTypeLogo(type)),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    option.serverName,
                    style: VText.small.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (latency != null)
                  Text('$latency ms', style: VText.small.copyWith(color: latency < 150 ? VColors.ok : VColors.warn)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 静态资源占位；屏外等待慢服务器时不持续产生动画帧。
class SourceSkeletonRow extends StatelessWidget {
  const SourceSkeletonRow({super.key});

  @override
  Widget build(BuildContext context) {
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(color: const Color(0x1AFFFFFF), borderRadius: BorderRadius.circular(6)),
    );
    final card = Container(
      width: SourceCard.width,
      height: SourceCard.height,
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        borderRadius: BorderRadius.circular(VRadius.card),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          bar(200, 28),
          const SizedBox(height: 16),
          bar(240, 18),
          const SizedBox(height: 10),
          bar(300, 16),
          const Spacer(),
          Row(children: [bar(24, 24), const SizedBox(width: 10), bar(140, 18)]),
        ],
      ),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(VSpace.safeH, 0, 0, 24),
      child: Row(children: [card, const SizedBox(width: 32), card, const SizedBox(width: 32), card]),
    );
  }
}

const _languages = {
  'chi': '中文',
  'zho': '中文',
  'zh': '中文',
  'chs': '简体中文',
  'cht': '繁体中文',
  'eng': '英语',
  'en': '英语',
  'jpn': '日语',
  'ja': '日语',
  'kor': '韩语',
  'ko': '韩语',
  'fre': '法语',
  'fra': '法语',
  'ger': '德语',
  'deu': '德语',
  'spa': '西班牙语',
  'ita': '意大利语',
  'rus': '俄语',
  'tha': '泰语',
  'und': '未知',
};

String _language(String? code) => code == null ? '' : _languages[code.toLowerCase()] ?? code;

/// 「展开媒体信息」：视频 / 音频 / 字幕参数与入库时间
class MediaInfoPanel extends StatelessWidget {
  const MediaInfoPanel({super.key, required this.option});

  final SourceOption option;

  @override
  Widget build(BuildContext context) {
    final source = option.source;
    final v = source.video;
    final audio = source.audio;
    final a = audio.where((s) => s.isDefault).firstOrNull ?? audio.firstOrNull;
    final subs = source.subtitles;
    final added = option.item.dateCreated?.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (source.name?.isNotEmpty == true) ...[
          Text(source.name!, style: VText.label.copyWith(color: VColors.textSecondary)),
          const SizedBox(height: 20),
        ],
        Wrap(
          spacing: 28,
          runSpacing: 28,
          children: [
            if (v != null)
              _InfoCard(
                title: '视频',
                rows: [
                  ('标题', v.title ?? v.streamTitle),
                  ('分辨率', v.width == null ? null : '${v.width} × ${v.height ?? '?'}'),
                  ('色彩范围', source.rangeLabel),
                  ('文件大小', source.size == null ? null : _gb(source.size!)),
                  ('码率', (v.bitrate ?? source.bitrate) == null ? null : _mbps(v.bitrate ?? source.bitrate!)),
                  ('帧率', v.frameRate == null ? null : _fps(v.frameRate!)),
                  ('编码', v.codec?.toUpperCase()),
                  ('配置', [?v.profile, if (v.level != null && v.level! > 0) 'Level ${v.level!.round()}'].join(' · ')),
                  ('基色', v.colorPrimaries),
                  ('色彩空间', v.colorSpace),
                  ('传输特性', v.colorTransfer),
                  ('深度', v.bitDepth == null ? null : '${v.bitDepth} bit'),
                ],
              ),
            if (a != null)
              _InfoCard(
                title: audio.length > 1 ? '音频 · 共 ${audio.length} 条' : '音频',
                rows: [
                  ('标题', a.title ?? a.streamTitle),
                  ('子标题', a.title != null && a.streamTitle != null && a.streamTitle != a.title ? a.streamTitle : null),
                  ('语言', _language(a.language)),
                  ('编码', a.codec?.toUpperCase()),
                  ('配置', a.profile),
                  ('声道数', a.channels == null ? null : '${a.channels}'),
                  ('声道布局', a.channelLayout ?? (a.channels == null ? null : _channels(a.channels!))),
                  ('采样率', a.sampleRate == null ? null : '${a.sampleRate} Hz'),
                  ('码率', a.bitrate == null ? null : '${(a.bitrate! / 1000).round()} kbps'),
                ],
              ),
            if (subs.isNotEmpty)
              _InfoCard(
                title: '字幕 · 共 ${subs.length} 条',
                rows: [
                  for (final s in subs.take(10))
                    (
                      s.isExternal ? '外挂' : '内封',
                      [s.title ?? _language(s.language), if (s.title == null) ?s.codec?.toUpperCase()].join(' · '),
                    ),
                  if (subs.length > 10) ('', '…'),
                ],
              ),
          ],
        ),
        if (added != null) ...[
          const SizedBox(height: 24),
          Text(
            '入库时间  ${added.year}-${two(added.month)}-${two(added.day)} ${two(added.hour)}:${two(added.minute)}',
            style: VText.caption.copyWith(color: VColors.textTertiary),
          ),
        ],
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.rows});

  final String title;
  final List<(String, String?)> rows;

  @override
  Widget build(BuildContext context) {
    final shown = rows.where((r) => r.$2 != null && r.$2!.trim().isNotEmpty).toList();
    return Container(
      width: 540,
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 22),
      decoration: BoxDecoration(
        color: const Color(0x12FFFFFF),
        borderRadius: BorderRadius.circular(VRadius.card),
        border: Border.all(color: const Color(0x1FFFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: VText.label.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          for (final (label, value) in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(label, style: VText.small.copyWith(color: VColors.textTertiary)),
                  ),
                  Expanded(
                    child: Text(value!, style: VText.small, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
