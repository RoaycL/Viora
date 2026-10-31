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
              // 和播放页一样：外面有一层铺满屏幕的焦点（画面本身）
              autofocus: true,
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
  });
}
