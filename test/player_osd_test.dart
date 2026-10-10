import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
