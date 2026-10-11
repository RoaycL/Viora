import 'dart:convert';

enum RatingMediaKind { movie, series, episode }

enum RatingSource {
  imdb('IMDb'),
  rottenTomatoes('烂番茄'),
  metacritic('Metacritic'),
  trakt('Trakt');

  const RatingSource(this.label);
  final String label;
}

/// IDs refer to this entity; a series ID is never treated as an episode ID.
class RatingQuery {
  const RatingQuery({
    required this.kind,
    this.imdbId,
    this.tmdbId,
    this.seriesImdbId,
    this.seriesTmdbId,
    this.season,
    this.episode,
  });

  final RatingMediaKind kind;
  final String? imdbId;
  final int? tmdbId;
  final String? seriesImdbId;
  final int? seriesTmdbId;
  final int? season;
  final int? episode;

  static bool validImdb(String? id) => id != null && RegExp(r'^tt\d+$').hasMatch(id);
  bool get hasEpisodeNumbers => season != null && season! >= 0 && episode != null && episode! > 0;
  bool get canLookup =>
      validImdb(imdbId) ||
      (kind != RatingMediaKind.episode && (tmdbId ?? 0) > 0) ||
      (kind == RatingMediaKind.episode && hasEpisodeNumbers && (validImdb(seriesImdbId) || (seriesTmdbId ?? 0) > 0));

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'imdb': imdbId,
    'tmdb': tmdbId,
    'series_imdb': seriesImdbId,
    'series_tmdb': seriesTmdbId,
    'season': season,
    'episode': episode,
  };

  String get identity => jsonEncode(toJson());
  @override
  bool operator ==(Object other) => other is RatingQuery && identity == other.identity;
  @override
  int get hashCode => identity.hashCode;
}

class ExternalRating {
  const ExternalRating({
    required this.source,
    required this.value,
    required this.scale,
    required this.kind,
    required this.entityId,
    this.votes,
  });

  final RatingSource source;
  final double value;
  final double scale;
  final int? votes;
  final RatingMediaKind kind;
  final String entityId;

  String get formatted => source == RatingSource.rottenTomatoes
      ? '${value.round()}%'
      : '${scale == 10 ? value.toStringAsFixed(1) : value.round()}/${scale.round()}';

  Map<String, Object?> toJson() => {
    'source': source.name,
    'value': value,
    'scale': scale,
    'votes': votes,
    'kind': kind.name,
    'entity': entityId,
  };

  factory ExternalRating.fromJson(Map<String, dynamic> json) {
    final value = (json['value'] as num).toDouble();
    final scale = (json['scale'] as num).toDouble();
    final votes = json['votes'] as int?;
    if (!value.isFinite ||
        !scale.isFinite ||
        scale <= 0 ||
        value < 0 ||
        value > scale ||
        (votes != null && votes <= 0)) {
      throw const FormatException('Invalid cached rating');
    }
    return ExternalRating(
      source: RatingSource.values.byName(json['source'] as String),
      value: value,
      scale: scale,
      votes: votes,
      kind: RatingMediaKind.values.byName(json['kind'] as String),
      entityId: json['entity'] as String,
    );
  }
}

/// Certification is descriptive metadata, not a content Parents Guide.
class RatingsData {
  const RatingsData({this.ratings = const [], this.certification});
  final List<ExternalRating> ratings;
  final String? certification;
  bool get isEmpty => ratings.isEmpty && certification == null;

  Map<String, Object?> toJson() => {'ratings': ratings.map((r) => r.toJson()).toList(), 'certification': certification};
  factory RatingsData.fromJson(Map<String, dynamic> json) => RatingsData(
    ratings: (json['ratings'] as List).map((r) => ExternalRating.fromJson((r as Map).cast<String, dynamic>())).toList(),
    certification: json['certification'] as String?,
  );
}

class RatingsResult {
  const RatingsResult(this.data, {this.fetchedAt, this.stale = false, this.error, this.unsupported = false});
  final RatingsData data;
  final DateTime? fetchedAt;
  final bool stale;
  final String? error;

  /// 缺少可查询的 ID（不是故障，详情页不提示、不显示重试）
  final bool unsupported;
}
