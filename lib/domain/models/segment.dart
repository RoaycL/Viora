enum SegmentType { intro, recap, credits, preview }

enum SegmentMediaKind { movie, episode }

/// Playback metadata needed for lookup. TV IDs identify the series, not the episode.
class SegmentQuery {
  const SegmentQuery({
    required this.titleKey,
    required this.kind,
    required this.duration,
    this.tmdbId,
    this.imdbId,
    this.season,
    this.episode,
    this.sourceKey = '',
  });

  final String titleKey;
  final SegmentMediaKind kind;
  final Duration duration;
  final int? tmdbId;
  final String? imdbId;
  final int? season;
  final int? episode;
  final String sourceKey;

  bool get hasEpisode => season != null && season! >= 0 && episode != null && episode! > 0;
  bool get canLookup => duration > Duration.zero && (kind == SegmentMediaKind.movie || hasEpisode);

  List<Object?> get cacheIdentity => [
    titleKey,
    kind.name,
    tmdbId,
    imdbId,
    season,
    episode,
    sourceKey,
    duration.inMilliseconds ~/ 10000,
  ];
}

/// Unvalidated provider data. A null end means the end of this playable file.
class SegmentCandidate {
  const SegmentCandidate({
    required this.type,
    required this.start,
    required this.end,
    required this.provider,
    this.confidence = 1,
    this.referenceDuration,
  });

  final SegmentType type;
  final Duration start;
  final Duration? end;
  final String provider;
  final double confidence;
  final Duration? referenceDuration;

  Map<String, Object?> toJson() => {
    'type': type.name,
    'start_ms': start.inMilliseconds,
    'end_ms': end?.inMilliseconds,
    'provider': provider,
    'confidence': confidence,
    'reference_duration_ms': referenceDuration?.inMilliseconds,
  };

  factory SegmentCandidate.fromJson(Map<String, dynamic> json) => SegmentCandidate(
    type: SegmentType.values.byName(json['type'] as String),
    start: Duration(milliseconds: json['start_ms'] as int),
    end: json['end_ms'] == null ? null : Duration(milliseconds: json['end_ms'] as int),
    provider: json['provider'] as String,
    confidence: (json['confidence'] as num).toDouble(),
    referenceDuration: json['reference_duration_ms'] == null
        ? null
        : Duration(milliseconds: json['reference_duration_ms'] as int),
  );
}

class Segment {
  const Segment({
    required this.type,
    required this.start,
    required this.end,
    required this.provider,
    required this.confidence,
  });

  final SegmentType type;
  final Duration start;
  final Duration end;
  final String provider;
  final double confidence;

  bool contains(Duration position) => position >= start && position < end;
}
