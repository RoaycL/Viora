import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/domain/models/segment.dart';
import 'package:viora/domain/models/segment_settings.dart';
import 'package:viora/domain/usecases/segment_resolver.dart';
import 'package:viora/player/segment_playback_session.dart';
import 'package:viora/player/segment_skip_controller.dart';

import 'segment_resolver_test.dart' show FakeProvider, candidate, query;

void main() {
  test('background lookup immediately uses latest position without blocking begin', () async {
    final data = Completer<List<SegmentCandidate>>();
    final seeks = <Duration>[];
    final done = Completer<void>();
    final session = SegmentPlaybackSession(
      resolver: SegmentResolver(providers: [FakeProvider('source', () => data.future)]),
      seek: (position) async {
        seeks.add(position);
        done.complete();
      },
      nextEpisode: () async {},
      onPrompt: (_) {},
    );
    session.begin(query, SegmentSettings.defaults().copyWith(intro: SegmentSkipMode.auto));
    session.onPosition(const Duration(seconds: 20));
    expect(seeks, isEmpty);
    data.complete([candidate('source', SegmentType.intro, 0, 60)]);
    await done.future;
    expect(seeks, [const Duration(seconds: 60)]);
    session.onPosition(const Duration(seconds: 21));
    expect(seeks, hasLength(1));
    session.dispose();
  });

  test('results from an old episode never attach after begin or dispose', () async {
    final data = Completer<List<SegmentCandidate>>();
    final provider = FakeProvider('source', () => data.future);
    final prompts = <SegmentSkipAction?>[];
    final session = SegmentPlaybackSession(
      resolver: SegmentResolver(providers: [provider]),
      seek: (_) async => fail('Stale episode seek'),
      nextEpisode: () async {},
      onPrompt: prompts.add,
    );
    session.begin(query, SegmentSettings.defaults());
    session.onPosition(const Duration(seconds: 20));
    session.dispose();
    data.complete([candidate('source', SegmentType.intro, 0, 60)]);
    await Future<void>.delayed(Duration.zero);
    expect(prompts.whereType<SegmentSkipAction>(), isEmpty);
  });

  test('continuous ticks do not issue concurrent seeks; failure offers manual retry', () async {
    final data = FakeProvider('source', () async => [candidate('source', SegmentType.intro, 0, 60)]);
    final seek = Completer<void>();
    var calls = 0;
    SegmentSkipAction? prompt;
    final session = SegmentPlaybackSession(
      resolver: SegmentResolver(providers: [data]),
      seek: (_) {
        calls++;
        return seek.future;
      },
      nextEpisode: () async {},
      onPrompt: (p) => prompt = p,
    );
    session.begin(query, SegmentSettings.defaults().copyWith(intro: SegmentSkipMode.auto));
    session.onPosition(const Duration(seconds: 20));
    await Future<void>.delayed(Duration.zero);
    for (var i = 21; i < 30; i++) {
      session.onPosition(Duration(seconds: i));
    }
    expect(calls, 1);
    seek.completeError(Exception('seek failed'));
    await Future<void>.delayed(Duration.zero);
    expect(prompt!.automatic, isFalse);
    session.onPosition(const Duration(seconds: 30));
    expect(calls, 1);
    session.dispose();
  });
}
