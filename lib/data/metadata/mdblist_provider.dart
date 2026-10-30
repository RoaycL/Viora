import '../../domain/models/external_rating.dart';
import '../../domain/models/ratings_settings.dart';
import 'rating_provider.dart';
import 'ratings_http.dart';

/// MDBList：按 IMDb / TMDB ID 一次取到 IMDb、烂番茄、Metacritic、Trakt 评分。
/// 和 OMDb 的区别是剧集（整剧）也有烂番茄分。单集没有评分，不查询。
///
/// 接口：`GET {base}/{imdb|tmdb}/{movie|show}/{id}?apikey=…`，返回
/// `{"type": "movie", "ratings": [{"source": "imdb", "value": 8.1, "votes": 123}, …], "certification": "PG-13"}`；
/// imdb 是 10 分制，tomatoes / metacritic / trakt 是 100 分制，没有的分数是 null。
class MdbListProvider implements RatingProvider {
  MdbListProvider({required this.apiKey, Uri? baseUrl, RatingJsonFetcher? fetcher})
    : baseUrl = baseUrl ?? Uri.parse(RatingProviderId.mdblist.defaultUrl),
      _fetch = fetcher ?? fetchRatingJson;
  final String apiKey;
  final Uri baseUrl;
  final RatingJsonFetcher _fetch;

  @override
  RatingProviderId get id => RatingProviderId.mdblist;

  @override
  bool supports(RatingQuery query) =>
      query.kind != RatingMediaKind.episode && (RatingQuery.validImdb(query.imdbId) || (query.tmdbId ?? 0) > 0);

  @override
  Future<RatingsData> fetch(RatingQuery query) async {
    if (!supports(query)) return const RatingsData();
    final byImdb = RatingQuery.validImdb(query.imdbId);
    final type = query.kind == RatingMediaKind.movie ? 'movie' : 'show';
    final body = await _fetch(
      ratingEndpoint(baseUrl, '${byImdb ? 'imdb' : 'tmdb'}/$type/${byImdb ? query.imdbId : query.tmdbId}', {
        'apikey': apiKey,
      }),
      const {},
    );
    if (body == null) return const RatingsData();
    final json = ratingObject(body);
    if (json['response'] == false) {
      // 业务错误也可能是 HTTP 200：只有确认没有这部作品才缓存为「没有评分」，额度、Key 错误不能缓存
      final error = '${json['error'] ?? ''}'.toLowerCase();
      if (error.contains('not found')) return const RatingsData();
      if (error.contains('limit')) {
        throw const RatingsException('MDBList 请求额度已达上限', retryAfter: Duration(minutes: 10));
      }
      if (error.contains('key')) throw const RatingsException('MDBList API Key 无效');
      throw const RatingsException('MDBList 查询失败，请检查 Key、额度或服务响应');
    }
    final returnedType = json['type'] ?? json['mediatype'];
    if (returnedType != null && returnedType != type) throw const RatingsException('MDBList 返回的作品类型不匹配');
    final ids = json['ids'] is Map ? json['ids'] as Map : const {};
    final entityId = byImdb ? query.imdbId! : '${ids['imdb'] ?? json['imdbid'] ?? 'tmdb:${query.tmdbId}'}';
    if (byImdb) {
      final imdb = ids['imdb'] ?? json['imdbid'];
      if (imdb != null && imdb != query.imdbId) throw const RatingsException('MDBList 返回的作品 ID 不匹配');
    }
    final rows = json['ratings'];
    if (rows != null && rows is! List) throw const RatingsException('MDBList 评分列表格式错误');
    final ratings = <ExternalRating>[];
    for (final row in (rows as List? ?? const []).whereType<Map<String, dynamic>>()) {
      final (source, scale) = switch (row['source']) {
        'imdb' => (RatingSource.imdb, 10.0),
        'tomatoes' => (RatingSource.rottenTomatoes, 100.0),
        'metacritic' => (RatingSource.metacritic, 100.0),
        'trakt' => (RatingSource.trakt, 100.0),
        _ => (null, 0.0),
      };
      if (source == null || ratings.any((r) => r.source == source)) continue;
      var value = ratingNumber(row['value'], scale);
      final counted = source == RatingSource.imdb || source == RatingSource.trakt;
      final votes = counted ? ratingVotes(row['votes']) : null;
      // MDBList 没有分数时有时给 0：当作没有；IMDb / Trakt 没有人投票的分数也不显示
      if (value == null || value == 0 || votes == 0) continue;
      var outOf = scale;
      // Trakt 在这里统一用 10 分制（与 Trakt 自己的接口一致）
      if (source == RatingSource.trakt) {
        value = value / 10;
        outOf = 10;
      }
      ratings.add(
        ExternalRating(source: source, value: value, scale: outOf, votes: votes, kind: query.kind, entityId: entityId),
      );
    }
    final certification = json['certification'];
    return RatingsData(
      ratings: ratings,
      certification: certification is String && certification.trim().isNotEmpty ? certification.trim() : null,
    );
  }
}
