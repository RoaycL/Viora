import 'package:flutter_test/flutter_test.dart';
import 'package:viora/domain/models/segment.dart';
import 'package:viora/domain/models/segment_settings.dart';
import 'package:viora/player/segment_skip_controller.dart';

const episode = SegmentQuery(
  titleKey: 'series',
  kind: SegmentMediaKind.episode,
  season: 1,
  episode: 2,
  duration: Duration(minutes: 50),
);
const intro = Segment(
  type: SegmentType.intro,
  start: Duration(seconds: 10),
  end: Duration(seconds: 70),
  provider: 'theintrodb',
  confidence: 1,
);
const recap = Segment(
  type: SegmentType.recap,
  start: Duration.zero,
  end: Duration(seconds: 10),
  provider: 'introdb',
  confidence: 1,
);
const credits = Segment(
  type: SegmentType.credits,
  start: Duration(minutes: 48),
  end: Duration(minutes: 50),
  provider: 'publicmetadb',
  confidence: 1,
);

void main() {
  test('default button mode uses half-open intervals; off never offers an action', () {
    final controller = SegmentSkipController(query: episode, settings: SegmentSettings.defaults())..segments = [intro];
    expect(controller.at(const Duration(seconds: 9)), isNull);
    expect(controller.at(const Duration(seconds: 10))!.automatic, isFalse);
    expect(controller.at(const Duration(seconds: 70)), isNull);
    final off = SegmentSkipController(
      query: episode,
      settings: SegmentSettings.defaults().copyWith(intro: SegmentSkipMode.off),
    )..segments = [intro];
    expect(off.at(const Duration(seconds: 20)), isNull);
  });

  test('auto intro and recap seek once, with independently configurable modes', () {
    final controller = SegmentSkipController(
      query: episode,
      settings: SegmentSettings.defaults().copyWith(intro: SegmentSkipMode.auto, recap: SegmentSkipMode.auto),
    )..segments = [recap, intro];
    final action = controller.at(const Duration(seconds: 20))!;
    expect(action.automatic, isTrue);
    expect(action.kind, SegmentSkipActionKind.seek);
    expect(action.target, intro.end);
    controller.markHandled(action);
    expect(controller.at(const Duration(seconds: 21)), isNull);
    expect(controller.at(const Duration(seconds: 5))!.segment.type, SegmentType.recap);
  });

  test('first episode exception shows an intro button but recap still auto-skips', () {
    const first = SegmentQuery(
      titleKey: 'series',
      kind: SegmentMediaKind.episode,
      season: 1,
      episode: 1,
      duration: Duration(minutes: 50),
    );
    final settings = SegmentSettings.defaults().copyWith(intro: SegmentSkipMode.auto, recap: SegmentSkipMode.auto);
    final controller = SegmentSkipController(query: first, settings: settings)..segments = [recap, intro];
    expect(controller.at(const Duration(seconds: 20))!.automatic, isFalse);
    expect(controller.at(const Duration(seconds: 5))!.automatic, isTrue);
    final disabled = SegmentSkipController(query: first, settings: settings.copyWith(firstEpisodeException: false))
      ..segments = [intro];
    expect(disabled.at(const Duration(seconds: 20))!.automatic, isTrue);
    const laterSeason = SegmentQuery(
      titleKey: 'series',
      kind: SegmentMediaKind.episode,
      season: 2,
      episode: 1,
      duration: Duration(minutes: 50),
    );
    final later = SegmentSkipController(query: laterSeason, settings: settings)..segments = [intro];
    expect(later.at(const Duration(seconds: 20))!.automatic, isTrue);
  });

  test('credits next episode requires a next item and credits reaching file end', () {
    final settings = SegmentSettings.defaults().copyWith(credits: SegmentSkipMode.auto);
    final next = SegmentSkipController(query: episode, settings: settings, hasNextEpisode: true)..segments = [credits];
    expect(next.at(const Duration(minutes: 49))!.kind, SegmentSkipActionKind.nextEpisode);
    final last = SegmentSkipController(query: episode, settings: settings)..segments = [credits];
    expect(last.at(const Duration(minutes: 49))!.kind, SegmentSkipActionKind.seek);
    const bounded = Segment(
      type: SegmentType.credits,
      start: Duration(minutes: 48),
      end: Duration(minutes: 49),
      provider: 'introdb',
      confidence: 1,
    );
    next.segments = [bounded];
    expect(next.at(const Duration(minutes: 48))!.kind, SegmentSkipActionKind.seek);
    expect(next.at(const Duration(minutes: 48))!.target, bounded.end);
  });

  test('a failed automatic action becomes a manual retry and never loops', () {
    final controller = SegmentSkipController(
      query: episode,
      settings: SegmentSettings.defaults().copyWith(intro: SegmentSkipMode.auto),
    )..segments = [intro];
    final action = controller.at(const Duration(seconds: 20))!;
    controller.markHandled(action);
    controller.retry(action);
    expect(controller.at(const Duration(seconds: 21))!.automatic, isFalse);
  });
}
