import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/segments/introdb_provider.dart';
import 'package:viora/data/segments/publicmetadb_provider.dart';
import 'package:viora/data/segments/theintrodb_provider.dart';
import 'package:viora/domain/models/segment.dart';

const episode = SegmentQuery(
  titleKey: 'tmdb:tv:1396',
  kind: SegmentMediaKind.episode,
  tmdbId: 1396,
  imdbId: 'tt0903747',
  season: 1,
  episode: 2,
  duration: Duration(seconds: 3000),
);

void main() {
  test('TheIntroDB v4 responses keyed by tvdb_id (no tmdb_id) are accepted', () async {
    final provider = TheIntroDbProvider(
      fetcher: (_, headers) async => {
        'tvdb_id': 81189,
        'type': 'tv',
        'season': 1,
        'episode': 2,
        'group_duration_ms': 2900000,
        'intro': [
          {'start_ms': null, 'end_ms': 60000, 'confidence': 0.8, 'submission_count': 5},
        ],
      },
    );
    final result = await provider.fetch(episode);
    expect(result.single.end, const Duration(seconds: 60));
    expect(result.single.referenceDuration, const Duration(milliseconds: 2900000));
  });

  test('an explicitly different episode response is rejected', () async {
    final provider = TheIntroDbProvider(
      fetcher: (_, headers) async => {
        'tmdb_id': 1396,
        'type': 'tv',
        'season': 1,
        'episode': 3,
        'intro': [
          {'start_ms': 0, 'end_ms': 60000},
        ],
      },
    );
    await expectLater(provider.fetch(episode), throwsFormatException);
  });
  test('TheIntroDB v4 uses series IDs, exact milliseconds and optional Bearer key', () async {
    final provider = TheIntroDbProvider(
      apiKey: 'user-key',
      fetcher: (uri, headers) async {
        expect(uri.toString(), startsWith('https://api.theintrodb.org/v4/media?'));
        expect(uri.queryParameters, {
          'tmdb_id': '1396',
          'season': '1',
          'episode': '2',
          'duration_ms': '3000000',
          'details': 'true',
        });
        expect(headers, {'Authorization': 'Bearer user-key'});
        return {
          'tmdb_id': 1396,
          'type': 'tv',
          'season': 1,
          'episode': 2,
          'intro': [
            {'start_ms': null, 'end_ms': 62500, 'confidence': 0.9},
          ],
          'recap': [
            {'start_ms': 70000, 'end_ms': 95000},
            {'start_ms': 110000, 'end_ms': 140000},
          ],
          'credits': [
            {'start_ms': 2850000, 'end_ms': null},
          ],
          'preview': [
            {'start_ms': 2950000, 'end_ms': null},
          ],
        };
      },
    );
    final result = await provider.fetch(episode);
    expect(result, hasLength(5));
    expect(result.first.start, Duration.zero);
    expect(result.first.end, const Duration(milliseconds: 62500));
    expect(result.first.confidence, 0.9);
    expect(result[3].end, isNull);
  });

  test('TheIntroDB supports IMDb fallback and movies without season/episode', () async {
    final provider = TheIntroDbProvider(
      fetcher: (uri, headers) async {
        expect(uri.queryParameters, {'imdb_id': 'tt0111161', 'duration_ms': '7200000', 'details': 'true'});
        expect(headers, isEmpty);
        return {'tmdb_id': 278, 'type': 'movie'};
      },
    );
    expect(
      await provider.fetch(
        const SegmentQuery(
          titleKey: 'movie',
          kind: SegmentMediaKind.movie,
          imdbId: 'tt0111161',
          duration: Duration(hours: 2),
        ),
      ),
      isEmpty,
    );
  });

  test('TheIntroDB ignores malformed timestamps and missing intro end', () async {
    final provider = TheIntroDbProvider(
      fetcher: (_, headers) async => {
        'intro': [
          {'start_ms': 0, 'end_ms': null},
          {'start_ms': '0', 'end_ms': 60000},
          {'start_ms': 0},
          {'start_ms': 5000, 'end_ms': 65000},
        ],
      },
    );
    expect(await provider.fetch(episode), hasLength(1));
  });

  test('IntroDB /segments maps seconds and outro, preserving post-credit content', () async {
    final provider = IntroDbProvider(
      apiKey: 'idb_user',
      fetcher: (uri, headers) async {
        expect(uri.path, '/segments');
        expect(uri.queryParameters, {'imdb_id': 'tt0903747', 'season': '1', 'episode': '2'});
        expect(headers, {'X-API-Key': 'idb_user'});
        return {
          'intro': {'start_sec': 2.5, 'end_sec': 62.75},
          'recap': {'start_ms': 70000, 'end_ms': 105000, 'confidence': 0.8},
          'outro': {'start_ms': 2850000, 'end_ms': 3000000},
          'post_credits': {'start_ms': 2950000, 'end_ms': 2990000},
        };
      },
    );
    final result = await provider.fetch(episode);
    expect(result.map((s) => s.type), [SegmentType.intro, SegmentType.recap, SegmentType.credits]);
    expect(result.first.start, const Duration(milliseconds: 2500));
    expect(result.first.end, const Duration(milliseconds: 62750));
    expect(result.last.end, const Duration(seconds: 2950));
  });

  test('IntroDB movie request uses is_movie and accepts clock-style values', () async {
    final provider = IntroDbProvider(
      fetcher: (uri, headers) async {
        expect(uri.queryParameters, {'imdb_id': 'tt0371746', 'is_movie': 'true'});
        return {
          'outro': {'start_sec': '1:59:00', 'end_sec': '2:06:00'},
        };
      },
    );
    final result = await provider.fetch(
      const SegmentQuery(
        titleKey: 'movie',
        kind: SegmentMediaKind.movie,
        imdbId: 'tt0371746',
        duration: Duration(minutes: 126),
      ),
    );
    expect(result.single.start, const Duration(minutes: 119));
    expect(result.single.end, const Duration(minutes: 126));
  });

  test('No ID or incomplete episode metadata makes no network request', () async {
    // Missing identity never falls back to a potentially incorrect title search.
    var calls = 0;
    Future<Object?> fetch(Uri uri, Map<String, String> headers) async {
      calls++;
      return {};
    }

    const query = SegmentQuery(
      titleKey: 'unknown',
      kind: SegmentMediaKind.episode,
      tmdbId: 1396,
      imdbId: 'tt0903747',
      season: 1,
      duration: Duration(minutes: 50),
    );
    expect(await IntroDbProvider(fetcher: fetch).fetch(query), isEmpty);
    expect(await TheIntroDbProvider(fetcher: fetch).fetch(query), isEmpty);
    expect(await PublicMetaDbProvider(apiKey: 'pmdb-user', fetcher: fetch).fetch(query), isEmpty);
    expect(calls, 0);
  });

  test('PublicMetaDB uses Bearer key, TMDB and millisecond contributor rows', () async {
    final provider = PublicMetaDbProvider(
      apiKey: 'pmdb-user',
      fetcher: (uri, headers) async {
        expect(uri.path, '/api/external/skips');
        expect(uri.queryParameters, {'tmdb_id': '1396', 'media_type': 'tv', 'season': '1', 'episode': '2'});
        expect(headers, {'Authorization': 'Bearer pmdb-user'});
        return {
          'items': [
            {'intro_start_ms': 0, 'intro_end_ms': 62000, 'credits_start_ms': 2880000},
            {'intro_start_ms': null, 'intro_end_ms': 65000},
          ],
        };
      },
    );
    final result = await provider.fetch(episode);
    expect(result, hasLength(2));
    expect(result.first.end, const Duration(seconds: 62));
    expect(result.last.type, SegmentType.credits);
    expect(result.last.end, isNull);
    expect(result.where((s) => s.type == SegmentType.recap), isEmpty);
  });

  test('PublicMetaDB missing key does not send an unauthenticated request', () async {
    var called = false;
    final provider = PublicMetaDbProvider(
      apiKey: '',
      fetcher: (_, headers) async {
        called = true;
        return {};
      },
    );
    expect(await provider.fetch(episode), isEmpty);
    expect(called, isFalse);
  });
}
