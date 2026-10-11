import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/platform_profile.dart';
import 'package:viora/app/app.dart';
import 'package:viora/data/tmdb/tmdb_client.dart';
import 'package:viora/ui/rows/focus_row.dart';

import 'focus_navigation_test.dart' as fixture;

void main() {
  setUp(() => PlatformProfile.debugOverride = PlatformProfile.tv);
  tearDown(() => PlatformProfile.debugOverride = PlatformProfile.desktop);

  if (const bool.fromEnvironment('VIORA_TV_PERF_BASELINE')) {
    testWidgets('TV 对照包关闭本批懒加载，仍保持原有行导航', (tester) async {
      final queried = <TmdbRow>{};
      await _pump(tester, queried);
      expect(queried, containsAll(TmdbRow.values));
      expect(find.byWidgetPredicate((w) => w is FocusRow && w.rowIndex == 9), findsOneWidget);
      await fixture.press(tester, LogicalKeyboardKey.arrowDown);
      expect(fixture.focused, 'row3#0');
      await fixture.unmount(tester);
    });
    return;
  }

  testWidgets('TV 首屏只请求附近推荐；深处行不会构建海报', (tester) async {
    final queried = <TmdbRow>{};
    await _pump(tester, queried);
    expect(queried, contains(TmdbRow.trendingDay));
    expect(queried, contains(TmdbRow.nowPlaying));
    expect(queried, isNot(contains(TmdbRow.topRatedTv)));
    expect(queried, isNot(contains(TmdbRow.trendingWeek)));
    expect(find.byWidgetPredicate((w) => w is FocusRow && w.rowIndex == 9), findsNothing);
    await fixture.press(tester, LogicalKeyboardKey.arrowDown);
    expect(fixture.focused, 'row3#0');
    await fixture.press(tester, LogicalKeyboardKey.arrowDown);
    expect(fixture.focused, 'row4#0');
    expect(queried, contains(TmdbRow.onTheAir));
    expect(tester.takeException(), isNull);
    await fixture.unmount(tester);
  });

  testWidgets('TV 遥控器可进入尚未构建的行，释放后恢复行记忆', (tester) async {
    await _pump(tester, {});
    await fixture.press(tester, LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 3; i++) {
      await fixture.press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(fixture.focused, 'row3#3');
    for (var i = 0; i < 5; i++) {
      await fixture.press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(fixture.focused, 'row9#0');
    expect(find.byWidgetPredicate((w) => w is FocusRow && w.rowIndex == 3), findsNothing);
    for (var i = 0; i < 5; i++) {
      await fixture.press(tester, LogicalKeyboardKey.arrowUp);
    }
    expect(fixture.focused, 'row3#3');
    await fixture.press(tester, LogicalKeyboardKey.escape);
    expect(fixture.focused, 'hero#0');
    expect(tester.takeException(), isNull);
    await fixture.unmount(tester);
  });

  testWidgets('TV 已加载的空推荐行不截断上下导航', (tester) async {
    final queried = <TmdbRow>{};
    await _pump(tester, queried, empty: TmdbRow.nowPlaying);
    expect(queried, contains(TmdbRow.onTheAir));
    await fixture.press(tester, LogicalKeyboardKey.arrowDown);
    expect(fixture.focused, 'row4#0');
    await fixture.press(tester, LogicalKeyboardKey.arrowUp);
    expect(fixture.focused, 'hero#0');
    await fixture.unmount(tester);
  });

  testWidgets('TV 推荐请求尚未完成仍可上下导航，迟到结果不会抢走焦点', (tester) async {
    final delayed = Completer<List<TmdbTitle>>();
    await _pump(tester, {}, delayed: delayed);
    await fixture.press(tester, LogicalKeyboardKey.arrowDown);
    expect(fixture.focused, 'deferred-row3');
    await fixture.press(tester, LogicalKeyboardKey.arrowDown);
    expect(fixture.focused, 'row4#0');
    delayed.complete(const []);
    await tester.pumpAndSettle();
    expect(fixture.focused, 'row4#0');
    await fixture.press(tester, LogicalKeyboardKey.arrowUp);
    expect(fixture.focused, 'hero#0');
    expect(tester.takeException(), isNull);
    await fixture.unmount(tester);
  });
}

Future<void> _pump(
  WidgetTester tester,
  Set<TmdbRow> queried, {
  TmdbRow? empty,
  Completer<List<TmdbTitle>>? delayed,
}) async {
  autoCheckUpdatesOnLaunch = false;
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        fixture.tmdbFixtures[0],
        tmdbRowProvider.overrideWith((ref, row) async {
          queried.add(row);
          if (row == TmdbRow.nowPlaying && delayed != null) return delayed.future;
          if (row == empty) return const <TmdbTitle>[];
          return [for (var i = 1; i <= 8; i++) fixture.fixtureTitle(row.index * 100 + i, '${row.name}-$i')];
        }),
        fixture.tmdbFixtures[2],
        fixture.tmdbFixtures[3],
      ],
      child: const VioraApp(),
    ),
  );
  await tester.pumpAndSettle();
}
