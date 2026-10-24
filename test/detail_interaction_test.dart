import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/input/intents.dart';
import 'package:viora/app/platform_profile.dart';
import 'package:viora/data/aggregate/sources.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/data/tmdb/tmdb_models.dart';
import 'package:viora/features/detail/episode_catalog.dart';
import 'package:viora/ui/rows/cards.dart';
import 'package:viora/features/detail/detail_layout.dart';
import 'package:viora/features/detail/detail_panels.dart';
import 'package:viora/features/detail/source_widgets.dart';
import 'package:viora/ui/focus/input_mode.dart';
import 'package:viora/ui/focus/row_focus.dart';
import 'package:viora/ui/widgets/buttons.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1920, 1080),
  double textScale = 1,
  bool reduced = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        shortcuts: appShortcuts,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced, textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Material(child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final _seasons = <SeasonChoice>[for (var i = 1; i <= 30; i++) (id: i, label: '第 $i 季'), (id: 0, label: '特别篇')];

SourceOption _source(int i) => SourceOption(
  item: const MediaItem(serverId: 's', id: 'movie', name: '电影', kind: MediaKind.movie),
  serverName: '服务器 $i',
  source: MediaSourceInfo(serverId: 's', itemId: 'movie', id: '$i', container: 'mkv'),
);

void main() {
  setUp(() {
    InputMode.install();
    PlatformProfile.debugOverride = PlatformProfile.tv;
  });
  tearDown(() => PlatformProfile.debugOverride = PlatformProfile.desktop);

  testWidgets('30 seasons open at current season, build visible choices, cancel restores trigger', (tester) async {
    Object? picked;
    await _pump(
      tester,
      RowFocusScope(
        child: SeasonSelector(seasons: _seasons, selected: 29, onSelect: (id) => picked = id),
      ),
      size: const Size(1280, 720),
    );
    final trigger = find.text('第 29 季');
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'season-28');
    expect(find.text('第 1 季'), findsNothing);
    expect(find.text('第 29 季'), findsNWidgets(2));
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'detail-panel-close');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'season-28');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(picked, isNull);
    expect(find.text('选择季 · 共 31 季'), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'buttons1#0');
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote traverses long season list and selects specials exactly once', (tester) async {
    var changes = 0;
    Object? picked;
    await _pump(
      tester,
      RowFocusScope(
        child: SeasonSelector(
          seasons: _seasons,
          selected: 1,
          onSelect: (id) {
            picked = id;
            changes++;
          },
        ),
      ),
      size: const Size(1280, 720),
    );
    await tester.tap(find.text('第 1 季'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 30; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'season-30');
    expect(tester.getRect(find.text('特别篇')).bottom, lessThan(720));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, 0);
    expect(changes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small season row scrolls to keyboard focus without overflowing narrow viewport', (tester) async {
    await _pump(
      tester,
      RowFocusScope(
        child: SeasonSelector(seasons: _seasons.take(6).toList(), selected: 1, onSelect: (_) {}),
      ),
      size: const Size(720, 540),
    );
    final scope = RowFocusScope.of(tester.element(find.byType(SeasonSelector)));
    scope.focusRow(1, index: 5);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('第 6 季')).right, lessThanOrEqualTo(720 - 40));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'buttons1#5');
    scope.focusRow(1, index: 0);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('第 1 季')).left, greaterThanOrEqualTo(40));
    expect(tester.takeException(), isNull);
  });

  testWidgets('complete overview scrolls with remote, closes with Escape and restores focus', (tester) async {
    final overview = List.filled(100, '这是完整的剧情介绍。').join('\n');
    final trigger = FocusNode(debugLabel: 'overview-trigger');
    addTearDown(trigger.dispose);
    await _pump(
      tester,
      Builder(
        builder: (context) => Center(
          child: PillButton(
            focusNode: trigger,
            label: '完整简介',
            onPressed: () => showDetailOverview(context, title: '长篇简介', overview: overview),
          ),
        ),
      ),
      size: const Size(1280, 720),
    );
    await tester.tap(find.text('完整简介'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(overview)).maxLines, isNull);
    final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(list.position.pixels, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(list.position.pixels, greaterThan(0));
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(trigger.hasPrimaryFocus, isTrue);
    expect(find.text('长篇简介'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows wheel scrolls overview without moving background page', (tester) async {
    PlatformProfile.debugOverride = PlatformProfile.desktop;
    final overview = List.filled(100, '可以用鼠标滚轮阅读的简介。').join('\n');
    final background = ScrollController();
    addTearDown(background.dispose);
    await _pump(
      tester,
      Builder(
        builder: (context) => SingleChildScrollView(
          controller: background,
          child: Column(
            children: [
              PillButton(
                label: '阅读',
                onPressed: () => showDetailOverview(context, title: '简介', overview: overview),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
      size: const Size(1280, 720),
      reduced: false,
    );
    await tester.tap(find.text('阅读'));
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(const PointerScrollEvent(position: Offset(640, 400), scrollDelta: Offset(0, 300)));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(
      find.ancestor(of: find.text(overview), matching: find.byType(Scrollable)).first,
    );
    expect(scroll.position.pixels, greaterThan(0));
    expect(background.offset, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text(overview), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('normal panel entrance can be interrupted by repeated back without popping page', (tester) async {
    await _pump(
      tester,
      Builder(
        builder: (context) => Center(
          child: PillButton(
            label: '阅读',
            onPressed: () => showDetailOverview(context, title: '简介', overview: '剧情'),
          ),
        ),
      ),
      reduced: false,
    );
    await tester.tap(find.text('阅读'));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('阅读'), findsOneWidget);
    expect(find.text('剧情'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resource shortcut reveals selected offscreen version without selecting or playing', (tester) async {
    final section = GlobalKey<SourcesSectionState>();
    var selectedCalls = 0, playCalls = 0;
    final options = List.generate(30, _source);
    await _pump(
      tester,
      DetailLayout(
        seed: 'test',
        backdrop: null,
        info: const Text('电影'),
        buttons: FocusButtonRow(
          rowIndex: 0,
          children: [
            (node) => PillButton(focusNode: node, label: '选择资源', onPressed: () => section.currentState!.reveal()),
          ],
        ),
        below: [
          SourcesSection(
            key: section,
            options: options,
            loading: false,
            selected: options[25],
            onSelect: (_) => selectedCalls++,
            onPlay: (_) => playCalls++,
            firstRow: 3,
          ),
        ],
      ),
    );
    await tester.tap(find.text('选择资源'));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'row4#25');
    expect(tester.getRect(find.text('服务器 25')).bottom, lessThan(1080));
    expect(selectedCalls, 0);
    expect(playCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resource loading anchor survives result arrival and static skeleton settles', (tester) async {
    final section = GlobalKey<SourcesSectionState>();
    late StateSetter update;
    var loading = true;
    final option = _source(1);
    await _pump(
      tester,
      StatefulBuilder(
        builder: (context, set) {
          update = set;
          return DetailLayout(
            seed: 'test',
            backdrop: null,
            info: const Text('电影'),
            buttons: FocusButtonRow(
              rowIndex: 0,
              children: [
                (node) => PillButton(focusNode: node, label: '选择资源', onPressed: () => section.currentState!.reveal()),
              ],
            ),
            below: [
              SourcesSection(
                key: section,
                options: loading ? [] : [option],
                loading: loading,
                selected: loading ? null : option,
                onSelect: (_) {},
                onPlay: (_) {},
                firstRow: 3,
                emptyText: '暂无资源',
              ),
            ],
          );
        },
      ),
    );
    await tester.tap(find.text('选择资源'));
    await tester.pumpAndSettle();
    final anchor = FocusManager.instance.primaryFocus;
    expect(anchor?.debugLabel, 'buttons3#0');
    expect(tester.binding.hasScheduledFrame, isFalse);
    update(() => loading = false);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(anchor));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'row4#0');
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text grows hero instead of painting title above viewport; buttons remain reachable', (
    tester,
  ) async {
    await _pump(
      tester,
      DetailLayout(
        seed: 'long',
        backdrop: null,
        info: const Column(
          children: [
            Text('很长的剧名与完整信息', style: TextStyle(fontSize: 100)),
            SizedBox(height: 600),
          ],
        ),
        buttons: FocusButtonRow(
          rowIndex: 0,
          scrollable: true,
          scrollToTop: true,
          children: [
            for (var i = 0; i < 8; i++) (node) => PillButton(focusNode: node, label: '操作按钮 $i', onPressed: () {}),
          ],
        ),
        below: const [],
      ),
      size: const Size(1000, 720),
      textScale: 1.5,
    );
    expect(tester.getTopLeft(find.text('很长的剧名与完整信息')).dy, greaterThanOrEqualTo(72));
    final ctx = tester.element(find.byType(FocusButtonRow));
    RowFocusScope.of(ctx).focusRow(0, index: 7);
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.text('操作按钮 7'));
    expect(rect.right, lessThan(1000));
    expect(rect.bottom, lessThan(720));
    expect(tester.takeException(), isNull);
  });

  testWidgets('async restart action insertion keeps held confirmation on original action', (tester) async {
    var restarting = false;
    var resourceCalls = 0, restartCalls = 0;
    late StateSetter update;
    await _pump(
      tester,
      StatefulBuilder(
        builder: (context, set) {
          update = set;
          return RowFocusScope(
            child: FocusButtonRow(
              rowIndex: 0,
              itemKeys: ['play', if (restarting) 'restart', 'resources'],
              children: [
                (node) => PillButton(focusNode: node, label: '播放', onPressed: () {}),
                if (restarting) (node) => PillButton(focusNode: node, label: '从头播放', onPressed: () => restartCalls++),
                (node) => PillButton(focusNode: node, label: '选择资源', onPressed: () => resourceCalls++),
              ],
            ),
          );
        },
      ),
    );
    final ctx = tester.element(find.byType(FocusButtonRow));
    final controller = RowFocusScope.of(ctx);
    controller.focusRow(0, index: 1);
    await tester.pumpAndSettle();
    final focused = FocusManager.instance.primaryFocus;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    update(() => restarting = true);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(focused));
    expect(controller.locate(focused), (row: 0, index: 2));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(resourceCalls, 1);
    expect(restartCalls, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(restartCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('200 episode catalog builds a window around selected future episode', (tester) async {
    int? picked;
    await _pump(
      tester,
      RowFocusScope(
        child: SingleChildScrollView(
          child: EpisodeCatalogRow(
            tvId: 42,
            season: 1,
            selected: 195,
            library: const [],
            libraryLoaded: true,
            episodes: [
              for (var i = 1; i <= 200; i++) TmdbEpisode(season: 1, number: i, name: '第 $i 集', airDate: DateTime(2099)),
            ],
            onSelect: (number) => picked = number,
          ),
        ),
      ),
    );
    expect(find.byType(LandscapeCard).evaluate().length, lessThan(15));
    final ctx = tester.element(find.byType(EpisodeCatalogRow));
    RowFocusScope.of(ctx).focusRow(2);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, 195);
    expect(find.textContaining('预计播出 2099-01-01'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('discarded account selector cannot commit its open season panel', (tester) async {
    Object? picked;
    late StateSetter update;
    var account = 'alice';
    await _pump(
      tester,
      StatefulBuilder(
        builder: (context, set) {
          update = set;
          return RowFocusScope(
            child: SeasonSelector(
              key: ValueKey(account),
              seasons: _seasons,
              selected: 29,
              onSelect: (id) => picked = id,
            ),
          );
        },
      ),
    );
    await tester.tap(find.text('第 29 季'));
    await tester.pumpAndSettle();
    update(() => account = 'bob');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, isNull);
    expect(find.text('选择季 · 共 31 季'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail loading is static, named and provides working back action', (tester) async {
    var backed = false;
    await _pump(
      tester,
      DetailLoading(seed: 'loading', onBack: () => backed = true),
      size: const Size(1280, 720),
    );
    expect(find.bySemanticsLabel('正在加载详情'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(backed, isTrue);
    expect(tester.takeException(), isNull);
  });
}
