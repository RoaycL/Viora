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
    this.criticRating,
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
    this.lastMediaAdded,
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

  /// 影评人评分（烂番茄新鲜度 0–100，媒体服务器的元数据提供）
  final double? criticRating;
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

  /// 剧集最近一次有新集入库的时间（服务器的 DateLastMediaAdded）
  final DateTime? lastMediaAdded;

  /// 「最近入库」排序用：剧集按最近一次更新新集，电影按入库时间
  DateTime? get addedAt => lastMediaAdded != null && (dateCreated == null || lastMediaAdded!.isAfter(dateCreated!))
      ? lastMediaAdded
      : dateCreated;

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
    'la': lastMediaAdded?.millisecondsSinceEpoch,
    'ov': overview,
    'or': officialRating,
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
    lastMediaAdded: j['la'] == null ? null : DateTime.fromMillisecondsSinceEpoch(j['la'] as int),
    overview: j['ov'] as String?,
    officialRating: j['or'] as String?,
  );

  /// 完整字段（页面快照用，见 SnapshotCache）
  Map<String, Object?> toCacheJson() => {
    's': serverId,
    'id': id,
    ...toIndexJson(),
    'pd': premiereDate?.millisecondsSinceEpoch,
    'or': officialRating,
    'cr': criticRating,
    'rt': runtime?.inMilliseconds,
    'th': thumb?.toJson(),
    'si': seriesId,
    'sn': seriesName,
    'ss': seasonId,
    'sx': seasonNumber,
    'ex': episodeNumber,
    'pl': played,
    'fv': favorite,
    'po': position.inMilliseconds,
    'pp': playedPercentage,
    'lp': lastPlayed?.millisecondsSinceEpoch,
  };

  static MediaItem fromCacheJson(Map<String, Object?> j) {
    final b = fromIndexJson(j['s'] as String, j['id'] as String, j);
    DateTime? t(String k) => j[k] == null ? null : DateTime.fromMillisecondsSinceEpoch(j[k] as int);
    return MediaItem(
      serverId: b.serverId,
      id: b.id,
      kind: b.kind,
      name: b.name,
      originalTitle: b.originalTitle,
      overview: b.overview,
      year: b.year,
      premiereDate: t('pd'),
      rating: b.rating,
      officialRating: j['or'] as String?,
      criticRating: (j['cr'] as num?)?.toDouble(),
      genres: b.genres,
      runtime: j['rt'] == null ? null : Duration(milliseconds: j['rt'] as int),
      tmdbId: b.tmdbId,
      imdbId: b.imdbId,
      tvdbId: b.tvdbId,
      primary: b.primary,
      backdrop: b.backdrop,
      thumb: ImageRef.fromJson(j['th']),
      logo: b.logo,
      seriesId: j['si'] as String?,
      seriesName: j['sn'] as String?,
      seasonId: j['ss'] as String?,
      seasonNumber: j['sx'] as int?,
      episodeNumber: j['ex'] as int?,
      childCount: b.childCount,
      played: j['pl'] as bool? ?? false,
      favorite: j['fv'] as bool? ?? false,
      position: Duration(milliseconds: j['po'] as int? ?? 0),
      playedPercentage: (j['pp'] as num?)?.toDouble(),
      dateCreated: b.dateCreated,
      lastMediaAdded: b.lastMediaAdded,
      lastPlayed: t('lp'),
    );
  }

  static List<Map<String, Object?>> encodeList(List<MediaItem> items) => [for (final it in items) it.toCacheJson()];

  static List<MediaItem> decodeList(Object? json) => [
    for (final j in json as List) fromCacheJson((j as Map).cast<String, Object?>()),
  ];

  /// `S1E3` 这样的集号
  String? get episodeLabel => seasonNumber != null && episodeNumber != null ? 'S${seasonNumber}E$episodeNumber' : null;
}

/// 一部剧的下一集：按季、集排序，季末接着下一季第一集；特别篇（第 0 季）只在特别篇之间连播
MediaItem? nextEpisodeAfter(List<MediaItem> episodes, MediaItem current) {
  final season = current.seasonNumber;
  final list =
      episodes
          .where((e) => e.kind == MediaKind.episode && e.seasonNumber != null && e.episodeNumber != null)
          .where((e) => season == 0 ? e.seasonNumber == 0 : e.seasonNumber != 0)
          .toList()
        ..sort((a, b) {
          final s = a.seasonNumber!.compareTo(b.seasonNumber!);
          return s != 0 ? s : a.episodeNumber!.compareTo(b.episodeNumber!);
        });
  final i = list.indexWhere((e) => e.id == current.id);
  if (i >= 0) return i + 1 < list.length ? list[i + 1] : null;
  // 当前集不在列表里（如没有集号）：取第一个排在它后面的
  if (season == null || current.episodeNumber == null) return null;
  return list
      .where((e) => e.seasonNumber! > season || (e.seasonNumber == season && e.episodeNumber! > current.episodeNumber!))
      .firstOrNull;
}

/// 剧集详情默认选中哪一集（季号, 集号）：最近看的那集没看完就是它，看完了就是下一集；没看过返回 null
(int, int)? pickStartEpisode(List<MediaItem> episodes) {
  final watched = episodes
      .where((e) => e.seasonNumber != null && e.episodeNumber != null && e.seasonNumber! > 0)
      .where((e) => e.lastPlayed != null || e.position > Duration.zero || e.played)
      .toList();
  if (watched.isEmpty) return null;
  int order(MediaItem e) => e.seasonNumber! * 10000 + e.episodeNumber!;
  // 有播放时间按时间，否则按集序取最靠后的
  watched.sort((a, b) {
    final ta = a.lastPlayed, tb = b.lastPlayed;
    if (ta != null && tb != null) return tb.compareTo(ta);
    if (ta != null || tb != null) return ta != null ? -1 : 1;
    return order(b).compareTo(order(a));
  });
  final last = watched.first;
  if (!last.played) return (last.seasonNumber!, last.episodeNumber!);
  final next = nextEpisodeAfter(episodes, last);
  return next == null ? (last.seasonNumber!, last.episodeNumber!) : (next.seasonNumber!, next.episodeNumber!);
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
    this.streamTitle,
    this.profile,
    this.level,
    this.colorPrimaries,
    this.colorSpace,
    this.colorTransfer,
    this.channelLayout,
    this.sampleRate,
    this.bitrate,
    this.aspectRatio,
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

  // 以下只用于详情页「展开媒体信息」
  /// 流自带的标题（[title] 优先用服务器拼好的 DisplayTitle）
  final String? streamTitle;
  final String? profile;
  final double? level;
  final String? colorPrimaries;
  final String? colorSpace;
  final String? colorTransfer;
  final String? channelLayout;
  final int? sampleRate;
  final int? bitrate;
  final String? aspectRatio;

  String get displayName {
    final parts = <String>[
      if (title != null && title!.isNotEmpty) title! else ?language,
      if (codec != null) codec!.toUpperCase(),
      if (channels != null) channels! >= 6 ? '${channels! - 1}.1' : '$channels.0',
    ];
    return parts.isEmpty ? '#$index' : parts.join(' · ');
  }
}

/// 一个可播放版本（docs/04-aggregation.md §5）
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
  const PagedItems(this.items, this.total, {this.rawCount, this.totalKnown = true});
  final List<MediaItem> items;
  final int total;
  final int? rawCount;
  final bool totalKnown;
  int get receivedCount => rawCount ?? items.length;
}

const ticksPerMicrosecond = 10;

Duration ticksToDuration(num? ticks) => Duration(microseconds: ((ticks ?? 0) / ticksPerMicrosecond).round());

int durationToTicks(Duration d) => d.inMicroseconds * ticksPerMicrosecond;
