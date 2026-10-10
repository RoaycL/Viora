import 'package:flutter/foundation.dart';

import '../media/media_models.dart';

/// TMDB 的电影 / 剧集条目（列表接口与详情接口共用）
@immutable
class TmdbTitle {
  const TmdbTitle({
    required this.id,
    required this.isTv,
    required this.title,
    this.originalTitle,
    this.overview = '',
    this.date,
    this.rating,
    this.posterPath,
    this.backdropPath,
    this.genreIds = const [],
    this.genres = const [],
    this.logoPath,
    this.runtimeMinutes,
    this.seasons,
    this.imdbId,
    this.tagline,
    this.cast = const [],
    this.recommendations = const [],
  });

  final int id;
  final bool isTv;
  final String title;
  final String? originalTitle;
  final String overview;
  final DateTime? date;
  final double? rating;
  final String? posterPath;
  final String? backdropPath;
  final List<int> genreIds;

  /// 详情接口才有
  final List<String> genres;
  final String? logoPath;
  final int? runtimeMinutes;
  final int? seasons;
  final String? imdbId;
  final String? tagline;
  final List<TmdbPerson> cast;
  final List<TmdbTitle> recommendations;

  MediaKind get kind => isTv ? MediaKind.series : MediaKind.movie;
  String get type => isTv ? 'tv' : 'movie';
  int? get year => date?.year;
  String get key => '$type/$id';

  /// 类型名（详情接口给出名字；列表接口只有 ID）
  List<String> get genreNames => genres.isNotEmpty ? genres : [for (final g in genreIds) ?tmdbGenreNames[g]];

  static TmdbTitle? fromJson(Map<String, dynamic> j, {bool? isTv}) {
    final media = j['media_type'] as String?;
    if (media != null && media != 'movie' && media != 'tv') return null;
    final tv = isTv ?? media == 'tv';
    final title = (tv ? j['name'] : j['title']) as String? ?? (j['title'] ?? j['name']) as String? ?? '';
    if (title.isEmpty) return null;
    final dateStr = (tv ? j['first_air_date'] : j['release_date']) as String? ?? '';
    final images = (j['images'] as Map?)?.cast<String, dynamic>();
    final credits = ((j['aggregate_credits'] ?? j['credits']) as Map?)?.cast<String, dynamic>();
    final recs = ((j['recommendations'] as Map?)?['results'] as List?) ?? const [];
    final vote = (j['vote_average'] as num?)?.toDouble();
    return TmdbTitle(
      id: j['id'] as int,
      isTv: tv,
      title: title,
      originalTitle: (tv ? j['original_name'] : j['original_title']) as String?,
      overview: j['overview'] as String? ?? '',
      date: DateTime.tryParse(dateStr),
      rating: vote == null || vote == 0 ? null : vote,
      posterPath: j['poster_path'] as String?,
      backdropPath: j['backdrop_path'] as String?,
      genreIds: [for (final g in (j['genre_ids'] as List? ?? const [])) g as int],
      genres: [for (final g in (j['genres'] as List? ?? const [])) (g as Map)['name'] as String],
      logoPath: images == null ? null : pickLogo(images['logos'] as List? ?? const []),
      runtimeMinutes:
          j['runtime'] as int? ??
          ((j['episode_run_time'] as List?)?.isNotEmpty == true ? (j['episode_run_time'] as List).first as int : null),
      seasons: j['number_of_seasons'] as int?,
      imdbId: j['imdb_id'] as String? ?? ((j['external_ids'] as Map?)?['imdb_id'] as String?),
      tagline: (j['tagline'] as String?)?.trim().isEmpty == true ? null : j['tagline'] as String?,
      cast: [
        for (final c in ((credits?['cast'] as List?) ?? const []).take(20))
          ?TmdbPerson.fromJson((c as Map).cast<String, dynamic>()),
      ],
      recommendations: [
        for (final r in recs) ?TmdbTitle.fromJson((r as Map).cast<String, dynamic>(), isTv: r['media_type'] == 'tv'),
      ],
    );
  }

  /// Logo 优先中文，其次英文，再其次无语言
  static String? pickLogo(List<dynamic> logos) {
    for (final lang in ['zh', 'en', null]) {
      for (final l in logos) {
        final m = (l as Map).cast<String, dynamic>();
        if (m['iso_639_1'] == lang && (m['file_path'] as String?)?.endsWith('.png') == true) {
          return m['file_path'] as String;
        }
      }
    }
    return null;
  }
}

@immutable
class TmdbPerson {
  const TmdbPerson({required this.id, required this.name, this.profilePath, this.role, this.biography});

  final int id;
  final String name;
  final String? profilePath;

  /// 角色名 / 部门
  final String? role;
  final String? biography;

  static TmdbPerson? fromJson(Map<String, dynamic> j) {
    final name = j['name'] as String?;
    if (name == null || name.isEmpty) return null;
    final roles = j['roles'] as List?;
    final character =
        j['character'] as String? ?? (roles?.isNotEmpty == true ? roles!.first['character'] as String? : null);
    return TmdbPerson(
      id: j['id'] as int,
      name: name,
      profilePath: j['profile_path'] as String?,
      role: character?.isNotEmpty == true ? character : _department(j['known_for_department'] as String?),
      biography: j['biography'] as String?,
    );
  }

  static String? _department(String? d) => switch (d) {
    'Acting' => '演员',
    'Directing' => '导演',
    'Writing' => '编剧',
    'Production' => '制片',
    null => null,
    _ => d,
  };
}

/// 播出平台（首页"播出平台"行，固定列表；Logo 来自 TMDB /network/{id}）
@immutable
class TmdbNetwork {
  const TmdbNetwork(this.id, this.name, this.logoPath);

  final int id;
  final String name;
  final String logoPath;
}

const tmdbNetworks = <TmdbNetwork>[
  TmdbNetwork(213, 'Netflix', '/wwemzKWzjKYJFfCeiB57q3r4Bcm.png'),
  TmdbNetwork(2739, 'Disney+', '/1edZOYAfoyZyZ3rklNSiUpXX30Q.png'),
  TmdbNetwork(49, 'HBO', '/tuomPhY2UtuPTqqFnKMVHvSb724.png'),
  TmdbNetwork(2552, 'Apple TV+', '/bngHRFi794mnMq34gfVcm9nDxN1.png'),
  TmdbNetwork(1024, 'Prime Video', '/w7HfLNm9CWwRmAMU58udl2L7We7.png'),
  TmdbNetwork(1330, '爱奇艺', '/fNxBFqWr7eWEgNeBDvvCxsSItXx.png'),
  TmdbNetwork(2007, '腾讯视频', '/6Lfll43wYG2eyereOBjpYFRSGs4.png'),
  TmdbNetwork(1419, '优酷', '/w2TeR3fvPZ9a617tNIF1oOfyPtk.png'),
  TmdbNetwork(1605, '哔哩哔哩', '/cdRh1NZIUaqDUhwjgqWbp6zhWHK.png'),
  TmdbNetwork(1631, '芒果TV', '/iE3rtBcUfWGiJosaZv2TroBxEZz.png'),
  TmdbNetwork(453, 'Hulu', '/pqUTCleNUiTLAVlelGxUgWn1ELh.png'),
];

/// TMDB 类型 ID → 中文名（电影与剧集合并）
const tmdbGenreNames = <int, String>{
  28: '动作',
  12: '冒险',
  16: '动画',
  35: '喜剧',
  80: '犯罪',
  99: '纪录',
  18: '剧情',
  10751: '家庭',
  14: '奇幻',
  36: '历史',
  27: '恐怖',
  10402: '音乐',
  9648: '悬疑',
  10749: '爱情',
  878: '科幻',
  10770: '电视电影',
  53: '惊悚',
  10752: '战争',
  37: '西部',
  10759: '动作冒险',
  10762: '儿童',
  10763: '新闻',
  10764: '真人秀',
  10765: '科幻奇幻',
  10766: '肥皂剧',
  10767: '脱口秀',
  10768: '战争政治',
};
