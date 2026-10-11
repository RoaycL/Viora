import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/metadata/rating_provider.dart';
import 'package:viora/data/metadata/ratings_cache.dart';
import 'package:viora/data/metadata/ratings_http.dart';
import 'package:viora/domain/models/external_rating.dart';
import 'package:viora/domain/models/ratings_settings.dart';
import 'package:viora/domain/usecases/ratings_resolver.dart';

const query = RatingQuery(kind: RatingMediaKind.movie, imdbId: 'tt3896198');
const data = RatingsData(
  ratings: [
    ExternalRating(
      source: RatingSource.imdb,
      value: 7.6,
      scale: 10,
      votes: 100,
      kind: RatingMediaKind.movie,
      entityId: 'tt3896198',
    ),
  ],
);

class FakeProvider implements RatingProvider {
  FakeProvider(this.id, this.load);
  @override
  final RatingProviderId id;
  final Future<RatingsData> Function(RatingQuery) load;
  int calls = 0;
  @override
  bool supports(RatingQuery query) => true;
  @override
  Future<RatingsData> fetch(RatingQuery query) {
    calls++;
    return load(query);
  }
}

void main() {
  test('deduplicates in-flight requests and persists only successful results', () async {
    final cache = MemoryRatingsCache();
    final ready = Completer<RatingsData>();
    final provider = FakeProvider(RatingProviderId.omdb, (_) => ready.future);
    final resolver = RatingsResolver(providers: {provider.id: provider}, cache: cache, namespace: 'test');
    final a = resolver.resolve(provider.id, query);
    final b = resolver.resolve(provider.id, query);
    await Future<void>.delayed(Duration.zero);
    expect(provider.calls, 1);
    ready.complete(data);
    expect((await a).data.ratings.single.value, 7.6);
    expect((await b).error, isNull);
    await resolver.resolve(provider.id, query);
    expect(provider.calls, 1);
    expect(cache.entries.length, 1);
  });

  test('per-provider failure never blocks another result or writes negative cache', () async {
    final blocked = Completer<RatingsData>();
    final slow = FakeProvider(RatingProviderId.trakt, (_) => blocked.future);
    final fast = FakeProvider(RatingProviderId.omdb, (_) async => data);
    final cache = MemoryRatingsCache();
    final resolver = RatingsResolver(
      providers: {slow.id: slow, fast.id: fast},
      cache: cache,
      namespace: 'test',
      timeout: const Duration(milliseconds: 50),
    );
    final pending = resolver.resolve(slow.id, query);
    expect((await resolver.resolve(fast.id, query)).data.ratings, isNotEmpty);
    expect((await pending).error, isNotNull);
    expect(cache.entries.length, 1);
    blocked.complete(const RatingsData());
  });

  test('expired cache survives network failure, but config namespaces cannot share it', () async {
    var now = DateTime.utc(2026, 10, 11);
    var fail = false;
    final provider = FakeProvider(RatingProviderId.omdb, (_) async {
      if (fail) throw Exception('secret-key must never appear');
      return data;
    });
    final cache = MemoryRatingsCache();
    final resolver = RatingsResolver(
      providers: {provider.id: provider},
      cache: cache,
      namespace: 'old',
      now: () => now,
    );
    await resolver.resolve(provider.id, query);
    now = now.add(const Duration(days: 2));
    fail = true;
    final stale = await resolver.resolve(provider.id, query);
    expect(stale.stale, isTrue);
    expect(stale.data.ratings, isNotEmpty);
    expect(stale.error, isNot(contains('secret-key')));
    final changed = RatingsResolver(providers: {provider.id: provider}, cache: cache, namespace: 'new', now: () => now);
    expect((await changed.resolve(provider.id, query)).data.ratings, isEmpty);
  });

  test('confirmed absence expires earlier; rate limits impose per-provider backoff', () async {
    var now = DateTime.utc(2026, 10, 11);
    final empty = FakeProvider(RatingProviderId.omdb, (_) async => const RatingsData());
    final limited = FakeProvider(
      RatingProviderId.trakt,
      (_) async => throw const RatingsException('limited', retryAfter: Duration(minutes: 2)),
    );
    final resolver = RatingsResolver(
      providers: {empty.id: empty, limited.id: limited},
      cache: MemoryRatingsCache(),
      namespace: 'test',
      now: () => now,
    );
    await resolver.resolve(empty.id, query);
    await resolver.resolve(empty.id, query);
    expect(empty.calls, 1);
    now = now.add(const Duration(hours: 7));
    await resolver.resolve(empty.id, query);
    expect(empty.calls, 2);
    await resolver.resolve(limited.id, query);
    await resolver.resolve(limited.id, const RatingQuery(kind: RatingMediaKind.series, imdbId: 'tt0903747'));
    expect(limited.calls, 1);
    now = now.add(const Duration(minutes: 3));
    await resolver.resolve(limited.id, query);
    expect(limited.calls, 2);
  });

  test('each provider admits at most two simultaneous requests', () async {
    final ready = Completer<RatingsData>();
    final p = FakeProvider(RatingProviderId.omdb, (_) => ready.future);
    final resolver = RatingsResolver(providers: {p.id: p}, cache: MemoryRatingsCache(), namespace: 'test');
    final requests = [
      for (var i = 1; i <= 4; i++) resolver.resolve(p.id, RatingQuery(kind: RatingMediaKind.movie, imdbId: 'tt$i')),
    ];
    await Future<void>.delayed(Duration.zero);
    expect(p.calls, 2);
    ready.complete(data);
    await Future.wait(requests);
    expect(p.calls, 4);
  });

  test('file cache survives restart, recovers corruption and contains no raw provider response', () async {
    final dir = await Directory.systemTemp.createTemp('viora-ratings-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/ratings.json');
    final first = FileRatingsCache(file);
    await first.write('hash', RatingsCacheEntry(DateTime.utc(2026, 10, 11), data));
    expect((await FileRatingsCache(file).read('hash'))!.data.ratings.single.value, 7.6);
    await file.writeAsString('[corrupt]');
    await first.write('new', RatingsCacheEntry(DateTime.utc(2026, 10, 11), data));
    expect(await first.read('hash'), isNull);
    expect((await file.readAsString()), isNot(contains('apikey')));
  });
}
