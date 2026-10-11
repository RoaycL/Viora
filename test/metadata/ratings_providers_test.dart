import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/metadata/omdb_provider.dart';
import 'package:viora/data/metadata/ratings_http.dart';
import 'package:viora/data/metadata/trakt_provider.dart';
import 'package:viora/domain/models/external_rating.dart';

// Relevant fields from the user's successful OMDb response; no credentials.
const omdbFixture = {
  'Title': 'Guardians of the Galaxy: Vol. 2',
  'Rated': 'PG-13',
  'Ratings': [
    {'Source': 'Internet Movie Database', 'Value': '7.6/10'},
    {'Source': 'Rotten Tomatoes', 'Value': '85%'},
    {'Source': 'Metacritic', 'Value': '67/100'},
  ],
  'Metascore': '67',
  'imdbRating': '7.6',
  'imdbVotes': '849,165',
  'imdbID': 'tt3896198',
  'Type': 'movie',
  'Response': 'True',
};
const movieQuery = RatingQuery(kind: RatingMediaKind.movie, imdbId: 'tt3896198');

void main() {
  test('OMDb uses canonical HTTPS lookup and parses the supplied real response', () async {
    final p = OmdbProvider(
      apiKey: 'test-key',
      baseUrl: Uri.parse('https://proxy.example/prefix'),
      fetcher: (uri, headers) async {
        expect(uri.path, '/prefix/');
        expect(uri.queryParameters, {'apikey': 'test-key', 'i': 'tt3896198', 'r': 'json'});
        expect(headers, isEmpty);
        return omdbFixture;
      },
    );
    final data = await p.fetch(movieQuery);
    expect(data.ratings.map((r) => r.source), [
      RatingSource.imdb,
      RatingSource.rottenTomatoes,
      RatingSource.metacritic,
    ]);
    expect(data.ratings.map((r) => r.formatted), ['7.6/10', '85%', '67/100']);
    expect(data.ratings.first.votes, 849165);
    expect(data.ratings[1].votes, isNull);
    expect(data.certification, 'PG-13');
  });

  test('OMDb unknown and zero-vote ratings are not displayed as genuine scores', () async {
    for (final score in ['N/A', 'NaN', '11', '-1', '7.6']) {
      final p = OmdbProvider(
        apiKey: 'test',
        fetcher: (_, _) async => {
          ...omdbFixture,
          'imdbRating': score,
          'imdbVotes': '0',
          'Metascore': 'N/A',
          'Ratings': [],
          'Rated': 'N/A',
        },
      );
      final data = await p.fetch(movieQuery);
      expect(data.isEmpty, isTrue);
    }
  });

  test('OMDb HTTP-200 auth/quota errors remain failures; confirmed absence is empty', () async {
    for (final error in ['Invalid API key!', 'Request limit reached!', 'unknown error']) {
      final p = OmdbProvider(apiKey: 'test', fetcher: (_, _) async => {'Response': 'False', 'Error': error});
      await expectLater(p.fetch(movieQuery), throwsA(isA<RatingsException>()));
    }
    final missing = OmdbProvider(
      apiKey: 'test',
      fetcher: (_, _) async => {'Response': 'False', 'Error': 'Movie not found!'},
    );
    expect((await missing.fetch(movieQuery)).isEmpty, isTrue);
  });

  test('OMDb rejects wrong identity/type and resolves episodes with a confirmed series ID', () async {
    for (final changed in [
      {'imdbID': 'tt0000001'},
      {'Type': 'series'},
    ]) {
      final p = OmdbProvider(apiKey: 'test', fetcher: (_, _) async => {...omdbFixture, ...changed});
      await expectLater(p.fetch(movieQuery), throwsA(isA<RatingsException>()));
    }
    const ep = RatingQuery(kind: RatingMediaKind.episode, seriesImdbId: 'tt0903747', season: 1, episode: 2);
    final p = OmdbProvider(
      apiKey: 'test',
      fetcher: (uri, _) async {
        expect(uri.queryParameters['i'], 'tt0903747');
        expect(uri.queryParameters['Season'], '1');
        expect(uri.queryParameters['Episode'], '2');
        return {
          ...omdbFixture,
          'Type': 'episode',
          'imdbID': 'tt1054724',
          'seriesID': 'tt0903747',
          'Season': '1',
          'Episode': '2',
        };
      },
    );
    expect((await p.fetch(ep)).ratings.first.kind, RatingMediaKind.episode);
  });

  test('Trakt public ratings send client ID/version headers and preserve 0-10 scale', () async {
    final p = TraktProvider(
      clientId: 'client',
      fetcher: (uri, headers) async {
        expect(uri.path, '/movies/tt3896198/ratings');
        expect(headers, {'trakt-api-version': '2', 'trakt-api-key': 'client'});
        expect(uri.queryParameters, isEmpty);
        return {'rating': 7.731, 'votes': 12345};
      },
    );
    final data = await p.fetch(movieQuery);
    expect(data.ratings.single.value, 7.731);
    expect(data.ratings.single.scale, 10);
    expect(data.ratings.single.votes, 12345);
  });

  test('Trakt TMDB mapping validates ID/type, caches mapping, and separates movie/show namespaces', () async {
    final paths = <String>[];
    final p = TraktProvider(
      clientId: 'client',
      fetcher: (uri, _) async {
        paths.add(uri.path);
        if (uri.path.startsWith('/search/')) {
          final type = uri.queryParameters['type']!;
          return [
            {
              'type': type,
              type: {
                'ids': {'tmdb': 123, 'trakt': type == 'movie' ? 1 : 2},
              },
            },
          ];
        }
        return {'rating': 8, 'votes': 10};
      },
    );
    await p.fetch(const RatingQuery(kind: RatingMediaKind.movie, tmdbId: 123));
    await p.fetch(const RatingQuery(kind: RatingMediaKind.movie, tmdbId: 123));
    await p.fetch(const RatingQuery(kind: RatingMediaKind.series, tmdbId: 123));
    expect(paths.where((p) => p.startsWith('/search/')).length, 2);
    expect(paths, containsAll(['/movies/1/ratings', '/shows/2/ratings']));
    final wrong = TraktProvider(
      clientId: 'client',
      fetcher: (_, _) async => [
        {
          'type': 'movie',
          'movie': {
            'ids': {'tmdb': 999, 'trakt': 1},
          },
        },
      ],
    );
    await expectLater(
      wrong.fetch(const RatingQuery(kind: RatingMediaKind.movie, tmdbId: 123)),
      throwsA(isA<RatingsException>()),
    );
  });

  test('Trakt episode route uses parent series ID, not the episode IMDb ID', () async {
    const query = RatingQuery(
      kind: RatingMediaKind.episode,
      imdbId: 'tt1054724',
      seriesImdbId: 'tt0903747',
      season: 1,
      episode: 2,
    );
    final p = TraktProvider(
      clientId: 'client',
      fetcher: (uri, _) async {
        expect(uri.path, '/shows/tt0903747/seasons/1/episodes/2/ratings');
        return {'rating': 8.5, 'votes': 200};
      },
    );
    expect((await p.fetch(query)).ratings.single.kind, RatingMediaKind.episode);
    expect(p.supports(const RatingQuery(kind: RatingMediaKind.episode, imdbId: 'tt1054724')), isFalse);
  });

  test('Trakt distinguishes zero votes from malformed data', () async {
    final zero = TraktProvider(clientId: 'client', fetcher: (_, _) async => {'rating': 0, 'votes': 0});
    expect((await zero.fetch(movieQuery)).isEmpty, isTrue);
    for (final data in [
      {'rating': 12, 'votes': 20},
      {'rating': 7.5},
      {'rating': 'NaN', 'votes': 1},
    ]) {
      final p = TraktProvider(clientId: 'client', fetcher: (_, _) async => data);
      await expectLater(p.fetch(movieQuery), throwsA(isA<RatingsException>()));
    }
  });
}
