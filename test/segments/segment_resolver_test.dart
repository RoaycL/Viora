import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/segments/segment_cache.dart';
import 'package:viora/data/segments/segment_http.dart';
import 'package:viora/data/segments/segment_provider.dart';
import 'package:viora/domain/models/segment.dart';
import 'package:viora/domain/usecases/segment_resolver.dart';

const query = SegmentQuery(
  titleKey: 'series',
  kind: SegmentMediaKind.episode,
  season: 1,
  episode: 2,
  duration: Duration(seconds: 3000),
);

SegmentCandidate candidate(
  String provider,
  SegmentType type,
  int start,
  int? end, {
  double confidence = 1,
  int? reference,
}) => SegmentCandidate(
  type: type,
  start: Duration(seconds: start),
  end: end == null ? null : Duration(seconds: end),
  provider: provider,
  confidence: confidence,
  referenceDuration: reference == null ? null : Duration(seconds: reference),
);

class FakeProvider implements SegmentProvider {
  FakeProvider(this.id, this.callback);
  @override
  final String id;
  final Future<List<SegmentCandidate>> Function() callback;
  int calls = 0;
  @override
  Future<List<SegmentCandidate>> fetch(SegmentQuery query) {
    calls++;
    return callback();
  }
}

void main() {
  test('per-type priority fills holes and retains multiple disjoint recaps', () async {
    final result = await SegmentResolver(
      providers: [
        FakeProvider('user', () async => [candidate('user', SegmentType.intro, 0, 60)]),
        FakeProvider(
          'server',
          () async => [
            candidate('server', SegmentType.intro, 5, 75),
            candidate('server', SegmentType.recap, 65, 100),
            candidate('server', SegmentType.recap, 110, 130),
          ],
        ),
        FakeProvider('introdb', () async => [candidate('introdb', SegmentType.credits, 2850, null)]),
      ],
    ).resolve(query);
    expect(result.segments.map((s) => s.provider), ['user', 'server', 'server', 'introdb']);
    expect(result.segments.last.end, query.duration);
  });

  test('invalid high-priority intervals fall back; spoofed provider never wins', () async {
    final result = await SegmentResolver(
      providers: [
        FakeProvider(
          'theintrodb',
          () async => [candidate('user', SegmentType.intro, 0, 60), candidate('theintrodb', SegmentType.intro, 0, 200)],
        ),
        FakeProvider('introdb', () async => [candidate('introdb', SegmentType.intro, 10, 70)]),
      ],
    ).resolve(query);
    expect(result.segments.single.provider, 'introdb');
  });

  test('requests run concurrently and one slow source cannot block others', () async {
    final first = Completer<List<SegmentCandidate>>();
    final second = Completer<List<SegmentCandidate>>();
    final p1 = FakeProvider('slow', () => first.future);
    final p2 = FakeProvider('fast', () => second.future);
    final pending = SegmentResolver(providers: [p1, p2], timeout: const Duration(milliseconds: 30)).resolve(query);
    await Future<void>.delayed(Duration.zero);
    expect([p1.calls, p2.calls], [1, 1]);
    second.complete([candidate('fast', SegmentType.intro, 0, 60)]);
    final result = await pending;
    expect(result.segments.single.provider, 'fast');
    expect(result.failures, {'slow': SegmentFailure.timeout});
    first.complete([]);
  });

  test('authorization, rate-limit and format errors are isolated by provider', () async {
    final result = await SegmentResolver(
      providers: [
        FakeProvider('auth', () async => throw const SegmentHttpException(401)),
        FakeProvider('limit', () async => throw const SegmentHttpException(429)),
        FakeProvider('format', () async => throw const FormatException('bad data')),
        FakeProvider('working', () async => [candidate('working', SegmentType.intro, 0, 60)]),
      ],
    ).resolve(query);
    expect(result.segments, hasLength(1));
    expect(result.failures, {
      'auth': SegmentFailure.unauthorized,
      'limit': SegmentFailure.rateLimited,
      'format': SegmentFailure.invalidResponse,
    });
  });

  test('validation covers intro length, location, credits boundary and confidence', () {
    Segment? valid(SegmentType type, int start, int? end, {double confidence = 1, int? reference}) =>
        SegmentResolver.validate(
          candidate('source', type, start, end, confidence: confidence, reference: reference),
          query.duration,
        );
    expect(valid(SegmentType.intro, -1, 60), isNull);
    expect(valid(SegmentType.intro, 0, 4), isNull);
    expect(valid(SegmentType.intro, 0, 5), isNotNull);
    expect(valid(SegmentType.intro, 0, 180), isNotNull);
    expect(valid(SegmentType.intro, 0, 181), isNull);
    expect(valid(SegmentType.intro, 1201, 1261), isNull);
    expect(valid(SegmentType.recap, 50, 50), isNull);
    expect(valid(SegmentType.recap, 50, 3100), isNull);
    expect(valid(SegmentType.recap, 0, null), isNull);
    expect(valid(SegmentType.credits, 1799, 3000), isNull);
    expect(valid(SegmentType.credits, 1800, 2700), isNotNull);
    expect(valid(SegmentType.credits, 1800, 2699), isNull);
    expect(valid(SegmentType.credits, 2850, null)!.end, query.duration);
    expect(valid(SegmentType.intro, 0, 60, confidence: double.nan), isNull);
    expect(valid(SegmentType.intro, 0, 60, confidence: 0.39), isNull);
    expect(valid(SegmentType.intro, 0, 60, confidence: 0.4), isNotNull);
    expect(valid(SegmentType.intro, 0, 60, confidence: 0.7, reference: 3031), isNull);
    expect(valid(SegmentType.intro, 0, 60, confidence: 0.8, reference: 3031)!.confidence, 0.4);
    expect(valid(SegmentType.intro, 0, 60, confidence: 0.7, reference: 3030)!.confidence, 0.7);
  });

  test('seven-day cache preserves raw null end and avoids double confidence penalty', () async {
    var now = DateTime.utc(2026, 10, 10);
    final cache = MemorySegmentCache();
    final provider = FakeProvider(
      'source',
      () async => [candidate('source', SegmentType.credits, 2900, null, confidence: 0.8, reference: 3031)],
    );
    final resolver = SegmentResolver(providers: [provider], cache: cache, now: () => now);
    final first = await resolver.resolve(query);
    final second = await resolver.resolve(query);
    expect(first.segments.single.confidence, 0.4);
    expect(second.segments.single.confidence, 0.4);
    expect(second.fromCache, isTrue);
    expect(provider.calls, 1);
    now = now.add(const Duration(days: 7));
    await resolver.resolve(query);
    expect(provider.calls, 2);
  });

  test('same duration bucket re-normalizes null end to the exact new duration', () async {
    final provider = FakeProvider('source', () async => [candidate('source', SegmentType.credits, 2900, null)]);
    final resolver = SegmentResolver(providers: [provider], cache: MemorySegmentCache());
    await resolver.resolve(query);
    const longer = SegmentQuery(
      titleKey: 'series',
      kind: SegmentMediaKind.episode,
      season: 1,
      episode: 2,
      duration: Duration(seconds: 3009),
    );
    final hit = await resolver.resolve(longer);
    expect(hit.fromCache, isTrue);
    expect(hit.segments.single.end, longer.duration);
  });

  test('transient failure is never cached as a seven-day negative result', () async {
    var fail = true;
    final provider = FakeProvider('source', () async {
      if (fail) throw const SegmentHttpException(503);
      return [candidate('source', SegmentType.intro, 0, 60)];
    });
    final resolver = SegmentResolver(providers: [provider], cache: MemorySegmentCache());
    expect((await resolver.resolve(query)).failures, isNotEmpty);
    fail = false;
    expect((await resolver.resolve(query)).segments, hasLength(1));
    expect(provider.calls, 2);
  });

  test('empty success has a short TTL and episode/source are part of cache identity', () async {
    var now = DateTime.utc(2026, 10, 10);
    final provider = FakeProvider('source', () async => []);
    final resolver = SegmentResolver(providers: [provider], cache: MemorySegmentCache(), now: () => now);
    await resolver.resolve(query);
    expect((await resolver.resolve(query)).fromCache, isTrue);
    now = now.add(const Duration(hours: 1));
    await resolver.resolve(query);
    await resolver.resolve(
      const SegmentQuery(
        titleKey: 'series',
        kind: SegmentMediaKind.episode,
        season: 1,
        episode: 3,
        duration: Duration(seconds: 3000),
      ),
    );
    await resolver.resolve(
      const SegmentQuery(
        titleKey: 'series',
        kind: SegmentMediaKind.episode,
        season: 1,
        episode: 2,
        sourceKey: 'extended-cut',
        duration: Duration(seconds: 3000),
      ),
    );
    expect(provider.calls, 4);
  });
}
