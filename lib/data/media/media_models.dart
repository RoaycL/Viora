/// 与服务器类型无关的媒体模型（docs/02-architecture.md §2）。
library;

enum MediaKind {
  movie,
  series,
  season,
  episode,
  folder,
  other;

  static MediaKind fromEmby(String? type) => switch (type) {
    'Movie' => movie,
    'Series' => series,
    'Season' => season,
    'Episode' => episode,
    'Folder' || 'CollectionFolder' || 'BoxSet' || 'UserView' => folder,
    _ => other,
  };
}

enum ImageKind { primary, backdrop, thumb, logo }

/// 图片引用：哪一个条目的哪种图（Emby 的图可能来自父级，如剧集的背景图）。
class ImageRef {
  const ImageRef(this.itemId, this.kind, {this.tag, this.index = 0});

  final String itemId;
  final ImageKind kind;
  final String? tag;
  final int index;

  List<Object?> toJson() => [itemId, kind.index, tag];

  static ImageRef? fromJson(Object? j) {
    if (j is! List || j.length < 2) return null;
    return ImageRef(j[0] as String, ImageKind.values[j[1] as int], tag: j.length > 2 ? j[2] as String? : null);
  }
}

class Library {
  const Library({required this.id, required this.name, this.collectionType, this.image});

  final String id;
  final String name;

  /// movies / tvshows / mixed / ...
  final String? collectionType;
  final ImageRef? image;
}

class MediaItem {
  const MediaItem({
    required this.serverId,
    required this.id,
    required this.kind,
    required this.name,
    this.originalTitle,
    this.overview,
    this.year,
    this.premiereDate,
    this.rating,
    this.officialRating,
    this.genres = const [],
    this.runtime,
    this.tmdbId,
    this.imdbId,
    this.tvdbId,
    this.primary,
    this.backdrop,
    this.thumb,
    this.logo,
    this.seriesId,
    this.seriesName,
    this.seasonId,
    this.seasonNumber,
    this.episodeNumber,
    this.childCount,
    this.played = false,
    this.favorite = false,
    this.position = Duration.zero,
    this.playedPercentage,
    this.dateCreated,
    this.lastPlayed,
  });

  final String serverId;
  final String id;
  final MediaKind kind;
  final String name;
  final String? originalTitle;
  final String? overview;
  final int? year;
  final DateTime? premiereDate;
  final double? rating;
  final String? officialRating;
  final List<String> genres;
  final Duration? runtime;
  final String? tmdbId;
  final String? imdbId;
  final String? tvdbId;
  final ImageRef? primary;
  final ImageRef? backdrop;
  final ImageRef? thumb;
  final ImageRef? logo;
  final String? seriesId;
  final String? seriesName;
  final String? seasonId;
  final int? seasonNumber;
  final int? episodeNumber;
  final int? childCount;
  final bool played;
  final bool favorite;

  /// 已播放位置（继续观看）
  final Duration position;
  final double? playedPercentage;
  final DateTime? dateCreated;

  /// 上次播放时间（继续观看跨服务器排序）
  final DateTime? lastPlayed;

  bool get playable => kind == MediaKind.movie || kind == MediaKind.episode || kind == MediaKind.other;

  /// 进度 0~1；没有进度时为 null
  double? get progress {
    if (playedPercentage != null && playedPercentage! > 0) return (playedPercentage! / 100).clamp(0, 1);
    final total = runtime?.inMilliseconds ?? 0;
    if (position > Duration.zero && total > 0) return (position.inMilliseconds / total).clamp(0, 1);
    return null;
  }

  /// 聚合索引里保存的字段（只用于电影 / 剧集卡片与匹配）
  Map<String, Object?> toIndexJson() => {
    'k': kind.index,
    'n': name,
    'o': originalTitle,
    'y': year,
    'r': rating,
    'g': genres,
    't': tmdbId,
    'i': imdbId,
    'v': tvdbId,
    'p': primary?.toJson(),
    'b': backdrop?.toJson(),
    'l': logo?.toJson(),
    'c': childCount,
    'd': dateCreated?.millisecondsSinceEpoch,
    'ov': overview,
  };

  static MediaItem fromIndexJson(String serverId, String id, Map<String, Object?> j) => MediaItem(
    serverId: serverId,
    id: id,
    kind: MediaKind.values[j['k'] as int? ?? MediaKind.other.index],
    name: j['n'] as String? ?? '',
    originalTitle: j['o'] as String?,
    year: j['y'] as int?,
    rating: (j['r'] as num?)?.toDouble(),
    genres: (j['g'] as List?)?.cast<String>() ?? const [],
    tmdbId: j['t'] as String?,
    imdbId: j['i'] as String?,
    tvdbId: j['v'] as String?,
    primary: ImageRef.fromJson(j['p']),
    backdrop: ImageRef.fromJson(j['b']),
    logo: ImageRef.fromJson(j['l']),
    childCount: j['c'] as int?,
    dateCreated: j['d'] == null ? null : DateTime.fromMillisecondsSinceEpoch(j['d'] as int),
    overview: j['ov'] as String?,
  );

  /// `S1E3` 这样的集号
  String? get episodeLabel => seasonNumber != null && episodeNumber != null ? 'S${seasonNumber}E$episodeNumber' : null;
}

enum VideoRange { sdr, hdr10, hdr10Plus, hlg, dolbyVision }

class MediaStreamInfo {
  const MediaStreamInfo({
    required this.index,
    required this.type,
    this.codec,
    this.language,
    this.title,
    this.isDefault = false,
    this.isExternal = false,
    this.channels,
    this.width,
    this.height,
    this.bitDepth,
    this.frameRate,
    this.range = VideoRange.sdr,
    this.deliveryUrl,
  });

  final int index;

  /// Video / Audio / Subtitle
  final String type;
  final String? codec;
  final String? language;
  final String? title;
  final bool isDefault;
  final bool isExternal;
  final int? channels;
  final int? width;
  final int? height;
  final int? bitDepth;
  final double? frameRate;
  final VideoRange range;
  final String? deliveryUrl;

  String get displayName {
    final parts = <String>[
      if (title != null && title!.isNotEmpty) title! else ?language,
      if (codec != null) codec!.toUpperCase(),
      if (channels != null) channels! >= 6 ? '${channels! - 1}.1' : '$channels.0',
    ];
    return parts.isEmpty ? '#$index' : parts.join(' · ');
  }
}

/// 一个可播放版本（docs/04-aggregation.md §7）
class MediaSourceInfo {
  const MediaSourceInfo({
    required this.serverId,
    required this.itemId,
    required this.id,
    required this.container,
    this.name,
    this.size,
    this.bitrate,
    this.duration,
    this.streams = const [],
    this.isRemote = false,
  });

  final String serverId;
  final String itemId;
  final String id;
  final String container;
  final String? name;
  final int? size;
  final int? bitrate;
  final Duration? duration;
  final List<MediaStreamInfo> streams;
  final bool isRemote;

  MediaStreamInfo? get video => streams.where((s) => s.type == 'Video').firstOrNull;
  List<MediaStreamInfo> get audio => streams.where((s) => s.type == 'Audio').toList();
  List<MediaStreamInfo> get subtitles => streams.where((s) => s.type == 'Subtitle').toList();

  String get resolutionLabel {
    final v = video;
    if (v == null || v.width == null) return '未知';
    final w = v.width!, h = v.height ?? 0;
    if (w >= 3200 || h >= 1800) return '4K';
    if (w >= 1800 || h >= 1000) return '1080P';
    if (w >= 1200 || h >= 700) return '720P';
    return 'SD';
  }

  String get rangeLabel => switch (video?.range ?? VideoRange.sdr) {
    VideoRange.sdr => 'SDR',
    VideoRange.hdr10 => 'HDR10',
    VideoRange.hdr10Plus => 'HDR10+',
    VideoRange.hlg => 'HLG',
    VideoRange.dolbyVision => 'Dolby Vision',
  };
}

class PagedItems {
  const PagedItems(this.items, this.total);
  final List<MediaItem> items;
  final int total;
}

const ticksPerMicrosecond = 10;

Duration ticksToDuration(num? ticks) => Duration(microseconds: ((ticks ?? 0) / ticksPerMicrosecond).round());

int durationToTicks(Duration d) => d.inMicroseconds * ticksPerMicrosecond;
