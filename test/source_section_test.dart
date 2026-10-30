import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/aggregate/sources.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/features/detail/source_widgets.dart';
import 'package:viora/ui/focus/row_focus.dart';

SourceOption _option(String id, {required int width, String server = '家里的 Emby'}) => SourceOption(
  item: MediaItem(
    serverId: 's1',
    id: 'movie',
    kind: MediaKind.movie,
    name: '沙丘',
    dateCreated: DateTime(2025, 3, 8, 21, 5),
  ),
  serverName: server,
  latencyMs: 42,
  source: MediaSourceInfo(
    serverId: 's1',
    itemId: 'movie',
    id: id,
    container: 'mkv',
    size: 58 * (1 << 30),
    bitrate: 72000000,
    streams: [
      MediaStreamInfo(
        index: 0,
        type: 'Video',
        codec: 'hevc',
        width: width,
        height: width * 9 ~/ 16,
        bitDepth: 10,
        frameRate: 23.976,
        range: VideoRange.dolbyVision,
        profile: 'Main 10',
        colorPrimaries: 'bt2020',
        colorSpace: 'bt2020nc',
      ),
      const MediaStreamInfo(
        index: 1,
        type: 'Audio',
        codec: 'truehd',
        language: 'eng',
        title: 'TrueHD Atmos 7.1',
        channels: 8,
        channelLayout: '7.1',
        sampleRate: 48000,
        isDefault: true,
      ),
    ],
  ),
);

void main() {
  test('自动换源按排序取第一个没试过的版本，全部试过时返回 null', () {
    final ranked = [_option('a', width: 3840), _option('b', width: 1920), _option('c', width: 1280)];
    expect(nextFailoverOption(ranked, {})?.source.id, 'a');
    expect(nextFailoverOption(ranked, {'s1/a'})?.source.id, 'b');
    expect(nextFailoverOption(ranked, {'s1/a', 's1/b'})?.source.id, 'c');
    expect(nextFailoverOption(ranked, {'s1/a', 's1/b', 's1/c'}), isNull);
  });

  Future<void> pump(WidgetTester tester, Widget section) async {
    tester.view.physicalSize = const Size(1920, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Material(
            child: RowFocusScope(child: SingleChildScrollView(child: section)),
          ),
        ),
      ),
    );
  }

  testWidgets('查找中显示占位卡片；没找到时只显示提示', (tester) async {
    await pump(
      tester,
      SourcesSection(
        options: const [],
        loading: true,
        selected: null,
        onSelect: (_) {},
        onPlay: (_) {},
        firstRow: 1,
        emptyText: '暂未找到资源',
      ),
    );
    expect(find.text('播放资源'), findsOneWidget);
    expect(find.byType(SourceSkeletonRow), findsOneWidget);
    expect(find.text('暂未找到资源'), findsNothing);

    await pump(
      tester,
      SourcesSection(
        options: const [],
        loading: false,
        selected: null,
        onSelect: (_) {},
        onPlay: (_) {},
        firstRow: 1,
        emptyText: '暂未找到资源',
      ),
    );
    expect(find.byType(SourceSkeletonRow), findsNothing);
    expect(find.text('暂未找到资源'), findsOneWidget);
  });

  testWidgets('点版本卡片先选中，再点一次播放；展开媒体信息', (tester) async {
    final a = _option('a', width: 3840), b = _option('b', width: 3840, server: '朋友的 Jellyfin');
    var selected = a;
    SourceOption? played;
    late StateSetter set;
    await pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          set = setState;
          return SourcesSection(
            options: [a, b],
            loading: false,
            selected: selected,
            onSelect: (o) => set(() => selected = o),
            onPlay: (o) => played = o,
            firstRow: 1,
          );
        },
      ),
    );
    expect(find.byType(SourceCard), findsNWidgets(2));
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);

    await tester.tap(find.text('朋友的 Jellyfin'));
    await tester.pump();
    expect(selected, same(b));
    expect(played, isNull);

    await tester.tap(find.text('朋友的 Jellyfin'));
    await tester.pump();
    expect(played, same(b));

    expect(find.text('视频'), findsNothing);
    await tester.tap(find.text('展开媒体信息'));
    await tester.pumpAndSettle();
    expect(find.text('视频'), findsOneWidget);
    expect(find.text('音频'), findsOneWidget);
    expect(find.text('3840 × 2160'), findsOneWidget);
    expect(find.text('Dolby Vision'), findsOneWidget);
    expect(find.text('英语'), findsOneWidget);
    expect(find.text('48000 Hz'), findsOneWidget);
    expect(find.textContaining('入库时间  2025-03-08 21:05'), findsOneWidget);
    expect(find.text('收起媒体信息'), findsOneWidget);
  });
}
