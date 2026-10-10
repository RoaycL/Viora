import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/app.dart';
import 'package:viora/app/input/intents.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/tmdb/tmdb_client.dart';

String? get focused => FocusManager.instance.primaryFocus?.debugLabel;

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

Future<void> pumpApp(WidgetTester tester) async {
  autoCheckUpdatesOnLaunch = false;
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(overrides: tmdbFixtures, child: const VioraApp()));
  await tester.pumpAndSettle();
}

/// 卸载应用，停止轮播 / 时钟等周期计时器。
Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

/// 测试用的 TMDB 数据（不联网）：每行 6 部
TmdbTitle fixtureTitle(int id, String title) =>
    TmdbTitle(id: id, isTv: true, title: title, backdropPath: '/b$id.jpg', posterPath: '/p$id.jpg', rating: 8.5);

final tmdbFixtures = [
  tmdbClientProvider.overrideWithValue(TmdbClient(const TmdbConfig(apiKey: 'test'), const ProxyConfig())),
  tmdbRowProvider.overrideWith(
    (ref, row) async => [
      fixtureTitle(row.index * 100 + 1, row == TmdbRow.trendingDay ? '时光代理人' : '${row.name}-1'),
      for (var i = 2; i <= 6; i++) fixtureTitle(row.index * 100 + i, '${row.name}-$i'),
    ],
  ),
  tmdbPeopleProvider.overrideWith((ref) async => const <TmdbPerson>[]),
  tmdbTitleProvider.overrideWith(
    (ref, key) async => TmdbTitle(id: key.id, isTv: key.isTv, title: '作品$key', overview: '简介'),
  ),
];

void main() {
  test('遥控器返回键、Esc、手柄 B 都映射为返回意图', () {
    for (final key in [LogicalKeyboardKey.goBack, LogicalKeyboardKey.escape, LogicalKeyboardKey.gameButtonB]) {
      final intent = appShortcuts.entries
          .where((e) => e.key is SingleActivator && (e.key as SingleActivator).trigger == key)
          .map((e) => e.value)
          .single;
      expect(intent, isA<BackIntent>());
    }
  });

  testWidgets('启动后焦点在 Hero 的播放按钮', (tester) async {
    await pumpApp(tester);
    expect(focused, 'hero#0');
    expect(find.text('时光代理人'), findsWidgets);
    await unmount(tester);
  });

  testWidgets('上下切换行时恢复每行上次的位置（行记忆）', (tester) async {
    await pumpApp(tester);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'row3#0');

    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused, 'row3#2');

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'row4#0');

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused, 'row3#2');

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focused, 'hero#0');
    await unmount(tester);
  });

  testWidgets('行尾按 → 不移动焦点', (tester) async {
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.pumpAndSettle();
    expect(focused, 'row3#5');
    await unmount(tester);
  });

  testWidgets('最左侧按 ← 进入导航栏当前项，按 → 回到原来的位置', (tester) async {
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused, 'row3#1');

    await press(tester, LogicalKeyboardKey.arrowLeft);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused, 'nav:/');

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused, 'row3#0');
    await unmount(tester);
  });

  testWidgets('返回键：先回到页面顶部的 Hero', (tester) async {
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'row4#0');

    await press(tester, LogicalKeyboardKey.escape);
    expect(focused, 'hero#0');
    await unmount(tester);
  });

  testWidgets('资源库：没有服务器时聚焦"添加服务器"，进入表单后返回键逐级返回', (tester) async {
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused, 'nav:/');

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'nav:/library');

    await press(tester, LogicalKeyboardKey.select);
    expect(find.text('还没有媒体服务器'), findsOneWidget);
    expect(focused, 'VFocusable');

    await press(tester, LogicalKeyboardKey.select);
    expect(find.text('连接并登录'), findsOneWidget);
    expect(focused, 'VTextField');

    // 输入框里按 ↓ 离开输入框
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused, 'VTextField');

    // 返回键（键盘 Esc）：表单 → 资源库 → 首页
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('还没有媒体服务器'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('时光代理人'), findsWidgets);
    await unmount(tester);
  });

  test('应用壳内页面的上一级', () {
    expect(parentLocation('/library/server/a/lib/b'), '/library/server/a');
    expect(parentLocation('/library/server/a'), '/library');
    expect(parentLocation('/library/add'), '/library');
    expect(parentLocation('/settings'), '/');
  });

  testWidgets('从卡片打开详情页，返回键回到首页', (tester) async {
    await pumpApp(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.select);
    expect(find.text('用关键词搜索'), findsOneWidget);
    expect(find.textContaining(RegExp('媒体库暂无资源|还没有添加服务器')), findsOneWidget);

    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('用关键词搜索'), findsNothing);
    expect(focused, 'row4#0');
    await unmount(tester);
  });

  testWidgets('导航栏：收起状态始终显示，焦点进入时展开、离开时收起', (tester) async {
    await pumpApp(tester);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    // 收起时只有图标
    expect(find.byIcon(Icons.dns_rounded), findsOneWidget);
    expect(find.text('资源库'), findsNothing);

    await press(tester, LogicalKeyboardKey.arrowLeft);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused, 'nav:/');
    expect(find.text('资源库'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('资源库'), findsNothing);
    await unmount(tester);
  });

  testWidgets('首次安装（没有服务器、没有 TMDB）：首页显示引导和推荐行占位，焦点在"添加服务器"', (tester) async {
    autoCheckUpdatesOnLaunch = false;
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(child: VioraApp()));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('欢迎使用 Viora'), findsOneWidget);
    expect(find.text('添加服务器'), findsOneWidget);
    expect(find.text('正在热映'), findsOneWidget);
    expect(find.text('配置 TMDB 后显示（设置 → 元数据）'), findsWidgets);
    expect(focused, isNotNull);
    await unmount(tester);
  });

  testWidgets('导航栏（鼠标）：移到上面展开，移开立即收起', (tester) async {
    await pumpApp(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1000, 900));
    addTearDown(mouse.removePointer);

    await mouse.moveTo(tester.getCenter(find.byIcon(Icons.dns_rounded)));
    await tester.pumpAndSettle();
    expect(find.text('资源库'), findsOneWidget);

    await mouse.moveTo(const Offset(1000, 900));
    await tester.pumpAndSettle();
    expect(find.text('资源库'), findsNothing);
    await unmount(tester);
  });
}
