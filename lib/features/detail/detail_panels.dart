import 'package:flutter/material.dart';

import '../../app/input/back_handler.dart';
import '../../app/input/intents.dart';
import '../../app/theme.dart';
import '../../ui/focus/focusable.dart';
import '../../ui/focus/row_focus.dart';
import '../../ui/widgets/buttons.dart';
import 'source_widgets.dart' show SelectChip;

typedef SeasonChoice = ({Object id, String label});

/// 少量季可以直接切换；长列表通过按需构建的面板选择，不占用整页宽度。
class SeasonSelector extends StatelessWidget {
  const SeasonSelector({super.key, required this.seasons, required this.selected, required this.onSelect});

  final List<SeasonChoice> seasons;
  final Object selected;
  final ValueChanged<Object> onSelect;

  @override
  Widget build(BuildContext context) {
    final current = seasons.where((s) => s.id == selected).firstOrNull ?? seasons.first;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VSpace.safeH),
      child: FocusButtonRow(
        rowIndex: 1,
        spacing: 12,
        scrollable: true,
        children: seasons.length <= 6
            ? [
                for (final season in seasons)
                  (node) => ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: SelectChip(
                      node: node,
                      label: season.label,
                      selected: season.id == current.id,
                      onTap: () => onSelect(season.id),
                    ),
                  ),
              ]
            : [
                (node) => ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: VFocusable(
                    focusNode: node,
                    semanticLabel: '选择季',
                    semanticValue: '${current.label}，共 ${seasons.length} 季',
                    radius: VRadius.pill,
                    scale: 1.03,
                    onActivate: () async {
                      final result = await _showPanel<Object>(
                        context,
                        title: '选择季 · 共 ${seasons.length} 季',
                        body: (close, finish) =>
                            _SeasonList(seasons: seasons, selected: current.id, close: close, onSelect: finish),
                      );
                      // 取消不改变选择；返回后仍停在触发按钮。
                      if (context.mounted && result != null && seasons.any((s) => s.id == result)) onSelect(result);
                    },
                    builder: (context, focused) => Container(
                      height: 68,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      decoration: BoxDecoration(
                        color: focused ? Colors.white : const Color(0x33FFFFFF),
                        borderRadius: BorderRadius.circular(VRadius.pill),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              current.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: VText.label.copyWith(color: focused ? VColors.background : Colors.white),
                            ),
                          ),
                          const SizedBox(width: 18),
                          Icon(Icons.unfold_more_rounded, color: focused ? VColors.background : Colors.white),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
      ),
    );
  }
}

Future<void> showDetailOverview(BuildContext context, {required String title, required String overview}) =>
    _showPanel<void>(
      context,
      title: title,
      body: (close, _) => _Overview(overview: overview, close: close),
    );

Future<T?> _showPanel<T>(
  BuildContext context, {
  required String title,
  required Widget Function(FocusNode close, ValueChanged<Object?> finish) body,
}) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: true,
  barrierLabel: '关闭详情面板',
  barrierColor: const Color(0xB307080B),
  transitionDuration: VMotion.duration(context, VMotion.focus),
  pageBuilder: (context, _, _) => _DetailPanel(title: title, body: body),
  transitionBuilder: (context, animation, _, child) => FadeTransition(
    opacity: animation,
    child: SlideTransition(
      position: Tween(
        begin: const Offset(0, 0.025),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ),
);

class _DetailPanel extends StatefulWidget {
  const _DetailPanel({required this.title, required this.body});
  final String title;
  final Widget Function(FocusNode close, ValueChanged<Object?> finish) body;

  @override
  State<_DetailPanel> createState() => _DetailPanelState();
}

class _DetailPanelState extends State<_DetailPanel> {
  final _close = FocusNode(debugLabel: 'detail-panel-close');
  final _body = FocusScopeNode(debugLabel: 'detail-panel-body');
  bool _closing = false;

  void _dismiss([Object? result]) {
    if (_closing || ModalRoute.of(context)?.isCurrent != true) return;
    _closing = true;
    Navigator.of(context).pop(result);
  }

  @override
  void dispose() {
    _close.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BackHandler(
    onBack: () {
      _dismiss();
      return true;
    },
    child: Shortcuts(
      shortcuts: appShortcuts,
      child: Actions(
        actions: {
          BackIntent: CallbackAction<BackIntent>(onInvoke: (_) => _dismiss()),
          DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
            onInvoke: (_) {
              final last = _body.focusedChild;
              if (last?.context != null) last!.requestFocus();
              return null;
            },
          ),
        },
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000, maxHeight: 900),
              child: Material(
                color: const Color(0xFF181B24),
                borderRadius: BorderRadius.circular(VRadius.panel),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: FocusTraversalGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: VText.h2),
                            ),
                            const SizedBox(width: 24),
                            Tooltip(
                              message: '关闭 · Esc / 返回',
                              child: CircleIconButton(
                                focusNode: _close,
                                icon: Icons.close_rounded,
                                tooltip: '关闭',
                                onPressed: _dismiss,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Expanded(
                          child: FocusScope(node: _body, child: widget.body(_close, _dismiss)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _SeasonList extends StatefulWidget {
  const _SeasonList({required this.seasons, required this.selected, required this.close, required this.onSelect});
  final List<SeasonChoice> seasons;
  final Object selected;
  final FocusNode close;
  final ValueChanged<Object> onSelect;

  @override
  State<_SeasonList> createState() => _SeasonListState();
}

class _SeasonListState extends State<_SeasonList> {
  final _nodes = <int, FocusNode>{};
  late ScrollController _scroll;
  late int _index;
  double _extent = 84;
  int _generation = 0;

  FocusNode _node(int index) => _nodes.putIfAbsent(index, () => FocusNode(debugLabel: 'season-$index'));

  @override
  void initState() {
    super.initState();
    _index = widget.seasons.indexWhere((s) => s.id == widget.selected).clamp(0, widget.seasons.length - 1);
    _scroll = ScrollController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _extent = MediaQuery.textScalerOf(context).scale(24) + 60;
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(_index));
  }

  Future<void> _reveal(int index) async {
    if (!mounted || !_scroll.hasClients) return;
    final generation = ++_generation;
    _index = index.clamp(0, widget.seasons.length - 1);
    final offset = (_index * _extent - (_scroll.position.viewportDimension - _extent) / 2).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    // 先挂载目标再请求焦点，快速长按只提交最后一次导航。
    _scroll.jumpTo(offset);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _generation || ModalRoute.of(context)?.isCurrent != true) return;
    _node(_index).requestFocus();
  }

  @override
  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
        onInvoke: (intent) {
          switch (intent.direction) {
            case TraversalDirection.up:
              if (_index == 0) {
                _generation++;
                widget.close.requestFocus();
              } else {
                _reveal(_index - 1);
              }
            case TraversalDirection.down:
              _reveal(_index + 1);
            case TraversalDirection.left:
            case TraversalDirection.right:
              _generation++;
              widget.close.requestFocus();
          }
          return null;
        },
      ),
    },
    child: Scrollbar(
      controller: _scroll,
      child: ListView.builder(
        controller: _scroll,
        itemExtent: _extent,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        itemCount: widget.seasons.length,
        itemBuilder: (context, i) {
          final season = widget.seasons[i];
          final selected = season.id == widget.selected;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: VFocusable(
              focusNode: _node(i),
              semanticLabel: season.label,
              selected: selected,
              scale: 1,
              onFocusChange: (focused) {
                if (focused) {
                  _generation++;
                  _index = i;
                }
              },
              onActivate: () => widget.onSelect(season.id),
              builder: (context, focused) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: focused
                      ? Colors.white
                      : selected
                      ? const Color(0x33FFFFFF)
                      : const Color(0x0DFFFFFF),
                  borderRadius: BorderRadius.circular(VRadius.md),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        season.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: VText.label.copyWith(color: focused ? VColors.background : Colors.white),
                      ),
                    ),
                    if (selected) Icon(Icons.check_rounded, color: focused ? VColors.background : Colors.white),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _Overview extends StatefulWidget {
  const _Overview({required this.overview, required this.close});
  final String overview;
  final FocusNode close;

  @override
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends State<_Overview> {
  final _scroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'detail-overview');
  bool _focused = false;

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _move(double direction) {
    final pos = _scroll.position;
    final target = (pos.pixels + pos.viewportDimension * .65 * direction).clamp(0.0, pos.maxScrollExtent);
    if (target == pos.pixels) {
      widget.close.requestFocus();
    } else if (VMotion.reduced(context)) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(target, duration: VMotion.scroll, curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
        onInvoke: (intent) {
          if (intent.direction == TraversalDirection.up) {
            _move(-1);
          } else if (intent.direction == TraversalDirection.down) {
            _move(1);
          } else {
            widget.close.requestFocus();
          }
          return null;
        },
      ),
    },
    child: Focus(
      focusNode: _focus,
      autofocus: true,
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: Listener(
        onPointerDown: (_) => _focus.requestFocus(),
        child: Semantics(
          label: '完整简介',
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: _focused ? VColors.focusRing : Colors.transparent, width: 2),
              borderRadius: BorderRadius.circular(VRadius.md),
            ),
            child: Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.all(16),
                child: Text(widget.overview, style: VText.body.copyWith(height: 1.65)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
