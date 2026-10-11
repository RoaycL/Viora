import '../../domain/models/external_rating.dart';
import '../../domain/models/ratings_settings.dart';
import 'rating_provider.dart';
import 'ratings_http.dart';

class TraktProvider implements RatingProvider {
  TraktProvider({required this.clientId, Uri? baseUrl, RatingJsonFetcher? fetcher})
    : baseUrl = baseUrl ?? Uri.parse(RatingProviderId.trakt.defaultUrl),
      _fetch = fetcher ?? fetchRatingJson;
  final String clientId;
  final Uri baseUrl;
  final RatingJsonFetcher _fetch;
  final _mappings = <String, Future<String?>>{};
  @override
  RatingProviderId get id => RatingProviderId.trakt;
  @override
  bool supports(RatingQuery query) => query.kind != RatingMediaKind.episode
      ? RatingQuery.validImdb(query.imdbId) || (query.tmdbId ?? 0) > 0
      : query.hasEpisodeNumbers && (RatingQuery.validImdb(query.seriesImdbId) || (query.seriesTmdbId ?? 0) > 0);

  Future<Object?> _get(String path, [Map<String, String> params = const {}]) =>
      _fetch(ratingEndpoint(baseUrl, path, params), {'trakt-api-version': '2', 'trakt-api-key': clientId});

  Future<String?> _id({required bool isTv, String? imdb, int? tmdb}) async {
    if (RatingQuery.validImdb(imdb)) return imdb;
    if (tmdb == null || tmdb <= 0) return null;
    final type = isTv ? 'show' : 'movie';
    final key = '$type/$tmdb';
    final existing = _mappings[key];
    if (existing != null) return existing;
    final task = _lookup(type, tmdb);
    if (_mappings.length >= 256) _mappings.remove(_mappings.keys.first);
    _mappings[key] = task;
    try {
      final result = await task;
      if (result == null) _mappings.remove(key);
      return result;
    } catch (_) {
      _mappings.remove(key);
      rethrow;
    }
  }

  Future<String?> _lookup(String type, int tmdb) async {
    final rows = await _get('search/tmdb/$tmdb', {'type': type});
    if (rows == null) return null;
    if (rows is! List) throw const RatingsException('Trakt ID 映射格式错误');
    final matches = <int>{};
    for (final row in rows.whereType<Map<String, dynamic>>()) {
      if (row['type'] != type) continue;
      final entity = row[type];
      final ids = entity is Map ? entity['ids'] : null;
      if (ids is! Map || ids['tmdb'] != tmdb || ids['trakt'] is! int || (ids['trakt'] as int) <= 0) continue;
      matches.add(ids['trakt'] as int);
    }
    if (matches.isEmpty && rows.isEmpty) return null;
    if (matches.length != 1) throw const RatingsException('Trakt 作品 ID 映射不匹配或有歧义');
    return '${matches.single}';
  }

  @override
  Future<RatingsData> fetch(RatingQuery query) async {
    if (!supports(query)) return const RatingsData();
    final episode = query.kind == RatingMediaKind.episode;
    final isTv = query.kind != RatingMediaKind.movie;
    final entity = await _id(
      isTv: isTv,
      imdb: episode ? query.seriesImdbId : query.imdbId,
      tmdb: episode ? query.seriesTmdbId : query.tmdbId,
    );
    if (entity == null) return const RatingsData();
    final path = episode
        ? 'shows/$entity/seasons/${query.season}/episodes/${query.episode}/ratings'
        : '${isTv ? 'shows' : 'movies'}/$entity/ratings';
    final body = await _get(path);
    if (body == null) return const RatingsData();
    final json = ratingObject(body);
    final score = ratingNumber(json['rating'], 10);
    final votes = ratingVotes(json['votes']);
    if (score == null || votes == null) throw const RatingsException('Trakt 评分或票数格式错误');
    if (votes == 0) return const RatingsData();
    return RatingsData(
      ratings: [
        ExternalRating(
          source: RatingSource.trakt,
          value: score,
          scale: 10,
          votes: votes,
          kind: query.kind,
          entityId: episode ? '$entity/${query.season}/${query.episode}' : entity,
        ),
      ],
    );
  }
}
