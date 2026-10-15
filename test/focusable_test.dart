import 'dart:ui' show SemanticsAction, SemanticsActionEvent, Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/input/intents.dart';
import 'package:viora/app/platform_profile.dart';
import 'package:viora/features/player/player_osd.dart';
import 'package:viora/ui/focus/focusable.dart';
import 'package:viora/ui/panels/form_dialog.dart';
import 'package:viora/ui/rows/cards.dart';
import 'package:viora/ui/widgets/art.dart';
import 'package:viora/ui/widgets/buttons.dart';
import 'package:viora/ui/widgets/form.dart';

Widget host(Widget child, {bool reduced = false}) => ProviderScope(
  child: MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(body: Center(child: child)),
    ),
  ),
);

Widget control({FocusNode? node, VoidCallback? activate, VoidCallback? menu, bool enabled = true}) => VFocusable(
  focusNode: node,
  autofocus: true,
  enabled: enabled,
  semanticLabel: '测试控件',
  onActivate: activate,
  onMenu: menu,
  builder: (_, focused) => SizedBox(width: 180, height: 100, child: Text(focused ? '已聚焦' : '普通')),
);

void main() {
  tearDown(() => PlatformProfile.debugOverride = PlatformProfile.desktop);

  testWidgets('短按只在确认键松开时执行；长按菜单不再触发普通操作', (tester) async {
    var activations = 0, menus = 0;
    PlatformProfile.debugOverride = PlatformProfile.tv;
    await tester.pumpWidget(host(control(activate: () => activations++, menu: () => menus++)));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 100));
    expect(activations, 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(activations, 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 300));
    expect(menus, 1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(activations, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('按住确认后移走焦点、再回来松键，不触发旧菜单或点击', (tester) async {
    final first = FocusNode(), second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    var actions = 0;
    await tester.pumpWidget(
      host(
        Column(
          children: [
            control(node: first, activate: () => actions++, menu: () => actions++),
            VFocusable(focusNode: second, onActivate: () {}, builder: (_, _) => const Text('另一个控件')),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 200));
    second.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    first.requestFocus();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    expect(actions, 0);
  });

  testWidgets('另一确认键的松开不能提交正在按住的操作', (tester) async {
    var actions = 0;
    await tester.pumpWidget(host(control(activate: () => actions++)));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(actions, 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    expect(actions, 1);
  });

  testWidgets('禁用时取消长按，保留焦点与不可用语义，屏蔽全部激活入口', (tester) async {
    var actions = 0;
    final node = FocusNode();
    addTearDown(node.dispose);
    final semantics = tester.ensureSemantics();
    Widget view(bool enabled) =>
        host(control(node: node, enabled: enabled, activate: () => actions++, menu: () => actions++));
    await tester.pumpWidget(view(true));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(view(false));
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.tap(find.byType(VFocusable));
    final ctx = tester.element(find.descendant(of: find.byType(VFocusable), matching: find.byType(Focus)).first);
    Actions.invoke(ctx, const MenuIntent());
    await tester.pump();
    expect(actions, 0);
    expect(node.hasFocus, isTrue);
    final data = tester.getSemantics(find.bySemanticsLabel('测试控件')).getSemanticsData();
    expect(data.flagsCollection.isEnabled, Tristate.isFalse);
    expect(data.flagsCollection.isFocused, Tristate.isTrue);
    expect(data.hasAction(SemanticsAction.tap), isFalse);
    expect(data.hasAction(SemanticsAction.longPress), isFalse);
    final mouse = tester.widget<MouseRegion>(
      find.descendant(of: find.byType(VFocusable), matching: find.byType(MouseRegion)).first,
    );
    expect(mouse.cursor, SystemMouseCursors.basic);
    semantics.dispose();
  });

  testWidgets('持有确认键时销毁控件会取消计时器', (tester) async {
    var actions = 0;
    await tester.pumpWidget(host(control(activate: () => actions++, menu: () => actions++)));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(actions, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('鼠标按下有反馈，取消拖动不执行；左键与右键各执行一次', (tester) async {
    var activations = 0, menus = 0;
    await tester.pumpWidget(host(control(activate: () => activations++, menu: () => menus++)));
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byType(VFocusable));
    final press = await tester.startGesture(center, kind: PointerDeviceKind.mouse);
    await tester.pump();
    final scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;
    expect(scale, lessThan(1.04));
    await press.cancel();
    await tester.pumpAndSettle();
    expect(activations, 0);
    await tester.tapAt(center);
    expect(activations, 1);
    final secondary = await tester.startGesture(center, kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await secondary.up();
    await tester.pump();
    expect(menus, 1);
    expect(activations, 1);
  });

  testWidgets('辅助技术 tap/longPress 有动作且图标命名不重复', (tester) async {
    var activations = 0, menus = 0;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(host(control(activate: () => activations++, menu: () => menus++)));
    await tester.pumpAndSettle();
    final node = tester.getSemantics(find.bySemanticsLabel('测试控件'));
    tester.binding.performSemanticsAction(
      SemanticsActionEvent(type: SemanticsAction.tap, nodeId: node.id, viewId: tester.view.viewId),
    );
    tester.binding.performSemanticsAction(
      SemanticsActionEvent(type: SemanticsAction.longPress, nodeId: node.id, viewId: tester.view.viewId),
    );
    expect(activations, 1);
    expect(menus, 1);
    await tester.pumpWidget(host(CircleIconButton(icon: Icons.favorite, tooltip: '收藏', onPressed: () {})));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('收藏'), findsOneWidget);
    expect(tester.getSemantics(find.bySemanticsLabel('收藏')).getSemanticsData().flagsCollection.isButton, isTrue);
    semantics.dispose();
  });

  testWidgets('没有回调的播放按钮仍是不可用的导航锚点', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(host(PillButton(focusNode: node, autofocus: true, label: '暂无资源')));
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue);
    expect(
      tester.getSemantics(find.bySemanticsLabel('暂无资源')).getSemanticsData().flagsCollection.isEnabled,
      Tristate.isFalse,
    );
    expect(find.text('暂无资源'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('辅助技术可以直接把输入焦点移回控件，不触发播放', (tester) async {
    final first = FocusNode(), second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    var actions = 0;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        Column(
          children: [
            control(node: first, activate: () => actions++),
            VFocusable(focusNode: second, onActivate: () {}, builder: (_, _) => const Text('另一个控件')),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    second.requestFocus();
    await tester.pumpAndSettle();
    expect(first.hasFocus, isFalse);
    final node = tester.getSemantics(find.bySemanticsLabel('测试控件'));
    expect(node.getSemanticsData().hasAction(SemanticsAction.focus), isTrue);
    tester.binding.performSemanticsAction(
      SemanticsActionEvent(type: SemanticsAction.focus, nodeId: node.id, viewId: tester.view.viewId),
    );
    await tester.pumpAndSettle();
    expect(first.hasFocus, isTrue);
    expect(actions, 0);
    semantics.dispose();
  });

  testWidgets('减少动效时无焦点缩放或持续忙碌动画，焦点仍可见', (tester) async {
    PlatformProfile.debugOverride = PlatformProfile.tv;
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      host(PillButton(focusNode: node, autofocus: true, label: '查找资源中', busy: true, onPressed: () {}), reduced: true),
    );
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue);
    expect(find.byType(AnimatedScale), findsNothing);
    expect(tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator)).value, isNotNull);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(host(control(activate: () {}), reduced: true));
    await tester.pumpAndSettle();
    final ring = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    expect(ring.duration, Duration.zero);
    expect((ring.foregroundDecoration! as BoxDecoration).border, isNotNull);
  });

  testWidgets('海报按钮朗读标题与状态一次，开关和单选报告当前值', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        SizedBox(
          width: PosterCard.width,
          height: PosterCard.height,
          child: PosterCard(
            node: node,
            art: const ArtSpec(Colors.black, Colors.black, Colors.black),
            title: '测试电影',
            subtitle: '2026',
            resources: 0,
            onActivate: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('测试电影'), findsOneWidget);
    final poster = tester.getSemantics(find.bySemanticsLabel('测试电影')).getSemanticsData();
    expect(poster.flagsCollection.isButton, isTrue);
    expect(poster.value, '2026，无资源');
    await tester.pumpWidget(host(VToggle(label: '自动跳过', value: true, onChanged: (_) {})));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.bySemanticsLabel('自动跳过')).getSemanticsData().flagsCollection.isToggled,
      Tristate.isTrue,
    );
    await tester.pumpWidget(
      host(VChoice(options: const [(1, '一'), (2, '二')], value: 2, onChanged: (_) {}, label: '选择')),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.bySemanticsLabel('二')).getSemanticsData().flagsCollection.isSelected,
      Tristate.isTrue,
    );
    semantics.dispose();
  });

  testWidgets('紧凑开关与排序按钮有名称，禁用按钮的焦点描边保持清晰', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(host(SmallSwitch(label: 'PublicMetaDB', value: false, onChanged: (_) {})));
    await tester.pumpAndSettle();
    final toggle = tester.getSemantics(find.bySemanticsLabel('PublicMetaDB')).getSemanticsData();
    expect(toggle.flagsCollection.isToggled, Tristate.isFalse);
    await tester.pumpWidget(
      host(const SmallIconButton(icon: Icons.arrow_upward, semanticLabel: '上移 PublicMetaDB', onPressed: null)),
    );
    await tester.pumpAndSettle();
    final button = tester.getSemantics(find.bySemanticsLabel('上移 PublicMetaDB')).getSemanticsData();
    expect(button.flagsCollection.isEnabled, Tristate.isFalse);
    expect(button.hasAction(SemanticsAction.tap), isFalse);
    final focus = tester.widget<Focus>(
      find.descendant(of: find.byType(VFocusable), matching: find.byType(Focus)).first,
    );
    focus.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    final ring = tester.widget<AnimatedContainer>(
      find.byWidgetPredicate((w) => w is AnimatedContainer && w.foregroundDecoration != null),
    );
    expect((ring.foregroundDecoration! as BoxDecoration).border, isNotNull);
    expect(find.ancestor(of: find.byType(VFocusable), matching: find.byType(Opacity)), findsNothing);
    semantics.dispose();
  });

  testWidgets('普通操作不朗读为未选中，分组按钮保留未选中状态', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(host(OsdTextButton(label: '倍速', onPressed: () {})));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.bySemanticsLabel('倍速')).getSemanticsData().flagsCollection.isSelected,
      Tristate.none,
    );
    await tester.pumpWidget(host(OsdTextButton(label: '1080P', selected: false, onPressed: () {})));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.bySemanticsLabel('1080P')).getSemanticsData().flagsCollection.isSelected,
      Tristate.isFalse,
    );
    semantics.dispose();
  });
}
