import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:viora/app/platform_profile.dart';
import 'package:viora/app/theme.dart';
import 'package:viora/features/home/home_hero.dart';
import 'package:viora/ui/focus/row_focus.dart';
import 'package:viora/ui/widgets/server_image.dart';

class HeroHarness extends StatefulWidget {
  const HeroHarness({super.key, this.autofocus = false, this.defer = false, this.longContent = false});
  final bool autofocus, defer, longContent;
  @override
  State<HeroHarness> createState() => HeroHarnessState();
}

class HeroHarnessState extends State<HeroHarness> {
  final outside = FocusNode(debugLabel: 'outside');
  int index = 0;
  int? pending;
  bool paused = false, visible = true, reduced = false;
  final selected = <int>[];
  final opened = <int>[];
  void update(VoidCallback change) => setState(change);
  @override
  void dispose() {
    outside.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: buildTheme(),
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(1920, 1080),
        disableAnimations: reduced,
        textScaler: TextScaler.linear(widget.longContent ? 1.5 : 1),
      ),
      child: Scaffold(
        body: RowFocusScope(
          child: Column(
            children: [
              TickerMode(
                enabled: visible,
                child: HomeHero(
                  rowIndex: 0,
                  height: 660,
                  autofocus: widget.autofocus,
                  index: index,
                  pendingIndex: pending,
                  rotationPaused: paused,
                  onToggleRotation: () => update(() => paused = !paused),
                  items: [
                    for (var i = 0; i < 3; i++)
                      HeroEntry(
                        key: '$i',
                        title: widget.longContent ? '这是一个需要分成两行展示的很长的作品标题 $i' : '推荐作品 $i',
                        art: placeholderArt('$i'),
                        badge: '今日趋势',
                        kindLabel: '剧集',
                        year: 2026,
                        genres: const ['动画', '动作冒险', '奇幻'],
                        overview: widget.longContent ? '在这里阅读作品简介，选择适合自己的故事。即使标题和简介很长，播放与切换操作也应该清楚、稳定、可访问。' : '',
                        onDetail: () => opened.add(i),
                      ),
                  ],
                  onIndexChanged: (next) => update(() {
                    selected.add(next);
                    if (widget.defer) {
                      pending = next;
                    } else {
                      index = next;
                    }
                  }),
                  onFocused: () {},
                ),
              ),
              TextButton(focusNode: outside, onPressed: () {}, child: const Text('其他区域')),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<HeroHarnessState> mountHero(
  WidgetTester tester, {
  bool autofocus = false,
  bool defer = false,
  bool longContent = false,
}) async {
  PlatformProfile.debugOverride = PlatformProfile.tv;
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: HeroHarness(autofocus: autofocus, defer: defer, longContent: longContent),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<HeroHarnessState>(find.byType(HeroHarness));
}

Future<void> removeHero(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  tearDown(() => PlatformProfile.debugOverride = PlatformProfile.desktop);

  testWidgets('焦点停留期间不轮播，离开后重新等待完整间隔', (tester) async {
    final state = await mountHero(tester, autofocus: true);
    await tester.pump(const Duration(seconds: 24));
    expect(state.index, 0);
    state.outside.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(seconds: 7));
    expect(state.index, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(state.index, 1);
    await removeHero(tester);
  });

  testWidgets('鼠标悬停暂停，移开后重新计时', (tester) async {
    final state = await mountHero(tester);
    state.outside.requestFocus();
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1800, 1000));
    await mouse.moveTo(const Offset(1800, 300));
    await tester.pump(const Duration(seconds: 20));
    expect(state.index, 0);
    await mouse.moveTo(const Offset(1800, 1000));
    await tester.pump(const Duration(seconds: 8));
    expect(state.index, 1);
    await mouse.removePointer();
    await removeHero(tester);
  });

  testWidgets('暂停按钮可操作，关闭自动轮播后手动切换仍可用', (tester) async {
    final state = await mountHero(tester);
    await tester.tap(find.bySemanticsLabel('暂停自动轮播'));
    await tester.pumpAndSettle();
    expect(state.paused, isTrue);
    state.outside.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(seconds: 24));
    expect(state.index, 0);
    await tester.tap(find.bySemanticsLabel('下一部推荐'));
    await tester.pumpAndSettle();
    expect(state.index, 1);
    expect(state.paused, isTrue);
    await removeHero(tester);
  });

  testWidgets('隐藏页面、后台和减少动画均停用轮播，恢复后重新计时', (tester) async {
    final state = await mountHero(tester);
    state.outside.requestFocus();
    state.update(() => state.visible = false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    expect(state.index, 0);
    state.update(() => state.visible = true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    expect(state.index, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 16));
    expect(state.index, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    state.update(() => state.reduced = true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    expect(state.index, 1);
    await tester.tap(find.bySemanticsLabel('下一部推荐'));
    await tester.pumpAndSettle();
    expect(state.index, 2);
    await removeHero(tester);
  });

  testWidgets('连续切换按最新目标累加，图片未准备好时当前作品操作保持一致', (tester) async {
    final state = await mountHero(tester, defer: true);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.bySemanticsLabel('下一部推荐'));
      await tester.pumpAndSettle();
    }
    expect(state.selected, [1, 2, 0]);
    expect(state.index, 0);
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(state.opened, [0]);
    await removeHero(tester);
  });

  testWidgets('遥控器可到达三个轮播控件，行尾不掉出 Hero', (tester) async {
    final state = await mountHero(tester, autofocus: true);
    for (var i = 1; i <= 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'hero#$i');
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'hero#3');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(state.index, 1);
    await removeHero(tester);
  });

  testWidgets('长标题、简介和大字体保留操作区，不产生布局溢出', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await mountHero(tester, longContent: true);
    expect(find.text('查看详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await removeHero(tester);
  });
}
