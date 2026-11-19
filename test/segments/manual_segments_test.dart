import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/domain/models/segment.dart';
import 'package:viora/domain/models/segment_settings.dart';
import 'package:viora/domain/usecases/segment_resolver.dart';
import 'package:viora/player/manual_segments.dart';
import 'package:viora/player/segment_playback_session.dart';
import 'package:viora/player/segment_skip_controller.dart';

import 'segment_resolver_test.dart' show FakeProvider, candidate;

const _ep = SegmentQuery(
  titleKey: 'tmdb:series:1',
  kind: SegmentMediaKind.episode,
  season: 1,
  episode: 2,
  duration: Duration(minutes: 24),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('片尾按「距离结尾」换算：每集时长不同也对得上；片头默认从 0 开始', () {
    const mark = ManualMark(introEnd: Duration(seconds: 90), creditsFromEnd: Duration(seconds: 100));
    final a = mark.segmentsFor(const Duration(minutes: 24));
    final b = mark.segmentsFor(const Duration(minutes: 23, seconds: 30));
    expect(a.map((s) => (s.type, s.start, s.end)), [
      (SegmentType.intro, Duration.zero, const Duration(seconds: 90)),
      (SegmentType.credits, const Duration(minutes: 22, seconds: 20), const Duration(minutes: 24)),
    ]);
    expect(b.last.start, const Duration(minutes: 21, seconds: 50));
    expect(a.every((s) => s.provider == 'manual'), isTrue);
  });

  test('剧集按「剧 + 季」保存：同一季别的集读到同一份，别的季没有', () async {
    await ManualSegmentStore.save(_ep, const ManualMark(introEnd: Duration(seconds: 80)));
    const sameSeason = SegmentQuery(
      titleKey: 'tmdb:series:1',
      kind: SegmentMediaKind.episode,
      season: 1,
      episode: 7,
      duration: Duration(minutes: 23),
    );
    const otherSeason = SegmentQuery(
      titleKey: 'tmdb:series:1',
      kind: SegmentMediaKind.episode,
      season: 2,
      episode: 1,
      duration: Duration(minutes: 23),
    );
    expect((await ManualSegmentStore.load(sameSeason))?.introEnd, const Duration(seconds: 80));
    expect(await ManualSegmentStore.load(otherSeason), isNull);
    expect(await ManualSegmentStore.count(), 1);
    await ManualSegmentStore.save(_ep, const ManualMark());
    expect(await ManualSegmentStore.count(), 0);
  });

  test('手动标记优先于数据源（同类型替换，其他类型保留）', () async {
    final seeks = <Duration>[];
    List<Segment> shown = const [];
    final session = SegmentPlaybackSession(
      resolver: SegmentResolver(
        providers: [
          FakeProvider(
            'source',
            () async => [
              candidate('source', SegmentType.intro, 0, 60),
              candidate('source', SegmentType.credits, 1300, null),
            ],
          ),
        ],
      ),
      seek: (p) async => seeks.add(p),
      nextEpisode: () async {},
      onPrompt: (_) {},
      onResolution: (r) => shown = r.segments,
    );
    session.begin(
      _ep,
      SegmentSettings.defaults().copyWith(intro: SegmentSkipMode.auto),
      position: const Duration(seconds: 5),
      manual: const ManualMark(introEnd: Duration(seconds: 85)).segmentsFor(_ep.duration),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(shown.map((s) => (s.type, s.provider)), [(SegmentType.intro, 'manual'), (SegmentType.credits, 'source')]);
    expect(seeks, [const Duration(seconds: 85)]);
    session.dispose();
  });

  test('播放中刚标完片尾开始：本次不立即跳走，下一次播放才生效', () async {
    final seeks = <Duration>[];
    var next = 0;
    final session = SegmentPlaybackSession(
      resolver: SegmentResolver(providers: [FakeProvider('source', () async => [])]),
      seek: (p) async => seeks.add(p),
      nextEpisode: () async => next++,
      onPrompt: (_) {},
    );
    session.begin(
      _ep,
      SegmentSettings.defaults().copyWith(credits: SegmentSkipMode.auto),
      hasNextEpisode: true,
      position: const Duration(minutes: 22),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    session.setManual(const ManualMark(creditsFromEnd: Duration(minutes: 2)).segmentsFor(_ep.duration));
    session.onPosition(const Duration(minutes: 22, seconds: 1));
    expect(next, 0);
    expect(seeks, isEmpty);
    session.dispose();
  });

  test('跳转被内核丢掉（刚打开文件）：位置没到目标就隔一会儿重发，到了就停', () async {
    final seeks = <Duration>[];
    var now = DateTime(2026);
    final session = SegmentPlaybackSession(
      resolver: SegmentResolver(providers: []),
      seek: (p) async => seeks.add(p),
      nextEpisode: () async {},
      onPrompt: (_) {},
      now: () => now,
    );
    session.begin(
      _ep,
      SegmentSettings.defaults().copyWith(intro: SegmentSkipMode.auto),
      manual: const ManualMark(introEnd: Duration(seconds: 90)).segmentsFor(_ep.duration),
    );
    session.onPosition(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(seeks, [const Duration(seconds: 90)]);
    // 内核没跳：位置还在开头。1.5 秒内不重发
    now = now.add(const Duration(milliseconds: 500));
    session.onPosition(const Duration(milliseconds: 500));
    expect(seeks, hasLength(1));
    now = now.add(const Duration(seconds: 1));
    session.onPosition(const Duration(milliseconds: 900));
    await Future<void>.delayed(Duration.zero);
    expect(seeks, hasLength(2));
    // 这次跳过去了：不再重发
    now = now.add(const Duration(seconds: 2));
    session.onPosition(const Duration(seconds: 90, milliseconds: 200));
    now = now.add(const Duration(seconds: 2));
    session.onPosition(const Duration(seconds: 91));
    expect(seeks, hasLength(2));
  });

  test('起播前已经跳过的片头：倒回去看不再被自动跳走', () async {
    final seeks = <Duration>[];
    final manual = const ManualMark(introEnd: Duration(seconds: 90)).segmentsFor(_ep.duration);
    final session = SegmentPlaybackSession(
      resolver: SegmentResolver(providers: []),
      seek: (p) async => seeks.add(p),
      nextEpisode: () async {},
      onPrompt: (_) {},
    );
    session.begin(
      _ep,
      SegmentSettings.defaults().copyWith(intro: SegmentSkipMode.auto),
      manual: manual,
      handled: [manual.first],
    );
    session.onPosition(const Duration(seconds: 95));
    session.onPosition(const Duration(seconds: 10));
    await Future<void>.delayed(Duration.zero);
    expect(seeks, isEmpty);
  });

  test('自动跳过重发几次都没生效：改为显示按钮，手动点能再跳', () async {
    final seeks = <Duration>[];
    final prompts = <SegmentSkipAction?>[];
    var now = DateTime(2026);
    final session = SegmentPlaybackSession(
      resolver: SegmentResolver(providers: []),
      seek: (p) async => seeks.add(p),
      nextEpisode: () async {},
      onPrompt: prompts.add,
      now: () => now,
    );
    session.begin(
      _ep,
      SegmentSettings.defaults().copyWith(intro: SegmentSkipMode.auto),
      manual: const ManualMark(introEnd: Duration(seconds: 90)).segmentsFor(_ep.duration),
    );
    for (var i = 0; i < 8; i++) {
      session.onPosition(Duration(seconds: i));
      await Future<void>.delayed(Duration.zero);
      now = now.add(const Duration(seconds: 2));
    }
    expect(seeks, hasLength(SegmentPlaybackSession.maxSeekAttempts));
    final button = prompts.lastWhere((p) => p != null);
    expect(button!.automatic, isFalse);
    await session.activate(button);
    expect(seeks, hasLength(SegmentPlaybackSession.maxSeekAttempts + 1));
  });

  test('起播直接跳过的片头其实没生效：重新打开后照常自动跳过', () async {
    final seeks = <Duration>[];
    final manual = const ManualMark(introEnd: Duration(seconds: 90)).segmentsFor(_ep.duration);
    final session = SegmentPlaybackSession(
      resolver: SegmentResolver(providers: []),
      seek: (p) async => seeks.add(p),
      nextEpisode: () async {},
      onPrompt: (_) {},
    );
    session.begin(
      _ep,
      SegmentSettings.defaults().copyWith(intro: SegmentSkipMode.auto),
      manual: manual,
      handled: [manual.first],
    );
    session.onPosition(const Duration(seconds: 3));
    await Future<void>.delayed(Duration.zero);
    expect(seeks, isEmpty);
    session.reopen(manual.first);
    await Future<void>.delayed(Duration.zero);
    expect(seeks, [const Duration(seconds: 90)]);
  });
}
