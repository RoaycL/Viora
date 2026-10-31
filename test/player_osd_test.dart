import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/platform_profile.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/features/player/player_osd.dart';
import 'package:viora/player/engine.dart';

void main() {
  testWidgets('控制层：Windows 有关闭 / 小窗 / 全屏；显示网速；点进度条跳到对应时间', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Duration? seekTo;
    var sources = 0;
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: PlayerOsd(
              state: const EngineState(
                position: Duration(seconds: 41),
                duration: Duration(minutes: 20),
                playing: true,
                buffering: false,
                speed: 6400000,
              ),
              title: '凡人修仙传 第 195 集',
              source: const MediaSourceInfo(
                serverId: 's',
                itemId: 'i',
                id: 'x',
                container: 'mkv',
                streams: [MediaStreamInfo(index: 0, type: 'Video', width: 3840, height: 2160)],
              ),
              pendingSeek: null,
              segments: const [],
              danmakuOn: true,
              isEpisode: true,
              hasNext: false,
              panel: OsdPanel.none,
              playNode: node,
              onBack: () {},
              onPlayPause: () {},
              onNext: () {},
              onSeek: (d) => seekTo = d,
              onDanmaku: () {},
              onDanmakuMenu: () {},
              onAudio: () {},
              onSubtitle: () {},
              onMore: () {},
              onSources: () => sources++,
              onEpisodes: () {},
              onRate: () {},
              onHoverControls: (_) {},
            ),
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('小窗播放'), findsOneWidget);
    expect(find.bySemanticsLabel('全屏'), findsOneWidget);
    expect(find.bySemanticsLabel('关闭'), findsOneWidget);
    expect(find.textContaining('6.1 MB/s'), findsOneWidget);
    expect(find.text('选集'), findsOneWidget);

    await tester.tap(find.text('4K'));
    expect(sources, 1);

    final bar = tester.getRect(find.byType(SeekBar));
    await tester.tapAt(Offset(bar.left + bar.width / 2, bar.center.dy));
    expect(seekTo, const Duration(minutes: 10));
  });

  test('网速格式', () {
    expect(formatSpeed(6400000), '6.1 MB/s');
    expect(formatSpeed(870400), '850 KB/s');
  });

  testWidgets('电视底部按钮行：←→ 按顺序移动，中间隔着空白也能到分辨率、选集、倍速，两端停住', (tester) async {
    PlatformProfile.debugOverride = PlatformProfile.tv;
    addTearDown(() => PlatformProfile.debugOverride = PlatformProfile.desktop);
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final node = FocusNode(debugLabel: 'play');
    addTearDown(node.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Focus(
              // 和播放页一样：外面有一层铺满屏幕的焦点（画面本身），不参与方向导航
              autofocus: true,
              skipTraversal: true,
              child: PlayerOsd(
                state: const EngineState(
                  position: Duration(seconds: 41),
                  duration: Duration(minutes: 20),
                  playing: true,
                  buffering: false,
                ),
                title: '凡人修仙传 第 194 集',
                source: const MediaSourceInfo(
                  serverId: 's',
                  itemId: 'i',
                  id: 'x',
                  container: 'mkv',
                  streams: [MediaStreamInfo(index: 0, type: 'Video', width: 3840, height: 2160)],
                ),
                pendingSeek: null,
                segments: const [],
                danmakuOn: true,
                isEpisode: true,
                hasNext: true,
                panel: OsdPanel.none,
                playNode: node,
                onBack: () {},
                onPlayPause: () {},
                onNext: () {},
                onSeek: (_) {},
                onDanmaku: () {},
                onDanmakuMenu: () {},
                onAudio: () {},
                onSubtitle: () {},
                onMore: () {},
                onSources: () {},
                onEpisodes: () {},
                onRate: () {},
                onHoverControls: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    node.requestFocus();
    await tester.pumpAndSettle();
    String? label() {
      final context = FocusManager.instance.primaryFocus?.context;
      return context == null
          ? null
          : tester
                .widget<Semantics>(
                  find
                      .ancestor(of: find.byElementPredicate((e) => e == context), matching: find.byType(Semantics))
                      .first,
                )
                .properties
                .label;
    }

    final seen = <String?>[label()];
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      seen.add(label());
    }
    expect(seen, ['暂停', '下一集', '4K', '选集', '倍速', '倍速', '倍速']);
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
    }
    expect(label(), '暂停');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(label(), '暂停');

    // ↑ 到顶部的弹幕 / 音轨 / 字幕 / 更多（按钮行只接管左右时 ↑ 会被吞掉）；顶部也按顺序左右移动、到两端停住
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(['弹幕：开', '音轨', '字幕', '更多'], contains(label()));
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
    }
    expect(label(), '弹幕：开');
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    expect(label(), '更多');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(['暂停', '下一集', '4K', '选集', '倍速'], contains(label()));
  });

  testWidgets('选集面板替换掉刚按下的按钮、集列表异步到达后，焦点落在正在看的那一集，←→ 可以切换', (tester) async {
    PlatformProfile.debugOverride = PlatformProfile.tv;
    addTearDown(() => PlatformProfile.debugOverride = PlatformProfile.desktop);
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final button = FocusNode(debugLabel: '选集按钮');
    addTearDown(button.dispose);
    final list = Completer<List<MediaItem>>();
    final panel = ValueNotifier(false);
    MediaItem? picked;
    MediaItem ep(int n) =>
        MediaItem(serverId: 's', id: 'e$n', name: '第 $n 集', kind: MediaKind.episode, seasonNumber: 1, episodeNumber: n);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Focus(
              autofocus: true,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: ValueListenableBuilder(
                  valueListenable: panel,
                  builder: (context, open, _) => open
                      ? EpisodesPanel(episodes: list.future, currentId: 'e2', onPick: (e) => picked = e)
                      : Focus(focusNode: button, child: const SizedBox(width: 80, height: 60)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    button.requestFocus();
    await tester.pumpAndSettle();
    panel.value = true;
    await tester.pump();
    list.complete([ep(1), ep(2), ep(3)]);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked?.id, 'e2');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked?.id, 'e3');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked?.id, 'e1');
  });
}
