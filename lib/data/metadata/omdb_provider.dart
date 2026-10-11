import '../../domain/models/external_rating.dart';
import '../../domain/models/ratings_settings.dart';
import 'rating_provider.dart';
import 'ratings_http.dart';

/// OMDb's canonical IMDb lookup. Never search by title or average ratings.
class OmdbProvider implements RatingProvider {
  OmdbProvider({required this.apiKey, Uri? baseUrl, RatingJsonFetcher? fetcher})
    : baseUrl = baseUrl ?? Uri.parse(RatingProviderId.omdb.defaultUrl),
      _fetch = fetcher ?? fetchRatingJson;
  final String apiKey;
  final Uri baseUrl;
  final RatingJsonFetcher _fetch;
  @override
  RatingProviderId get id => RatingProviderId.omdb;
  @override
  bool supports(RatingQuery query) =>
      RatingQuery.validImdb(query.imdbId) ||
      (query.kind == RatingMediaKind.episode && query.hasEpisodeNumbers && RatingQuery.validImdb(query.seriesImdbId));

  @override
  Future<RatingsData> fetch(RatingQuery query) async {
    if (!supports(query)) return const RatingsData();
    final bySeries = !RatingQuery.validImdb(query.imdbId);
    final body = await _fetch(
      ratingEndpoint(baseUrl, '', {
        'apikey': apiKey,
        'i': bySeries ? query.seriesImdbId! : query.imdbId!,
        'r': 'json',
        if (bySeries) 'Season': '${query.season}',
        if (bySeries) 'Episode': '${query.episode}',
      }),
      const {},
    );
    if (body == null) return const RatingsData();
    final json = ratingObject(body);
    if (json['Response'] != 'True') {
      // A business error can arrive with HTTP 200. Only a confirmed missing
      // title is negative-cacheable; never save auth/quota errors as no data.
      final error = json['Error'];
      if (error == 'Movie not found!' || error == 'Episode not found!') return const RatingsData();
      if (error is String && error.toLowerCase().contains('limit')) {
        throw const RatingsException('OMDb 请求额度已达上限', retryAfter: Duration(minutes: 5));
      }
      throw const RatingsException('OMDb 查询失败，请检查 Key、额度或服务响应');
    }
    final imdb = json['imdbID'];
    if (json['Type'] != query.kind.name ||
        !RatingQuery.validImdb(imdb is String ? imdb : null) ||
        (!bySeries && imdb != query.imdbId) ||
        (bySeries &&
            (json['seriesID'] != query.seriesImdbId ||
                json['Season']?.toString() != '${query.season}' ||
                json['Episode']?.toString() != '${query.episode}'))) {
      throw const RatingsException('OMDb 返回的作品 ID 或类型不匹配');
    }
    final ratings = <ExternalRating>[];
    final votes = ratingVotes(json['imdbVotes']);
    final imdbScore = ratingNumber(json['imdbRating'], 10);
    if (imdbScore != null && votes != 0) {
      ratings.add(
        ExternalRating(
          source: RatingSource.imdb,
          value: imdbScore,
          scale: 10,
          votes: votes,
          kind: query.kind,
          entityId: imdb as String,
        ),
      );
    }
    final rows = json['Ratings'];
    if (rows != null && rows is! List) throw const RatingsException('OMDb 评分列表格式错误');
    for (final row in (rows as List? ?? const []).whereType<Map<String, dynamic>>()) {
      final source = switch (row['Source']) {
        'Rotten Tomatoes' => RatingSource.rottenTomatoes,
        'Metacritic' => RatingSource.metacritic,
        _ => null,
      };
      if (source == null || ratings.any((r) => r.source == source)) continue;
      final text = row['Value'];
      if (text is! String) continue;
      final suffix = source == RatingSource.rottenTomatoes ? '%' : '/100';
      if (!text.endsWith(suffix)) continue;
      final score = ratingNumber(text.substring(0, text.length - suffix.length), 100);
      if (score != null) {
        ratings.add(
          ExternalRating(source: source, value: score, scale: 100, kind: query.kind, entityId: imdb as String),
        );
      }
    }
    final metascore = ratingNumber(json['Metascore'], 100);
    if (metascore != null && !ratings.any((r) => r.source == RatingSource.metacritic)) {
      ratings.add(
        ExternalRating(
          source: RatingSource.metacritic,
          value: metascore,
          scale: 100,
          kind: query.kind,
          entityId: imdb as String,
        ),
      );
    }
    final rated = json['Rated'];
    return RatingsData(
      ratings: ratings,
      certification: rated is String && rated.isNotEmpty && rated != 'N/A' ? rated : null,
    );
  }
}
