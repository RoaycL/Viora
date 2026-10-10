import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../media/media_models.dart';
import '../media/zh.dart';
import '../net/request_composer.dart';

/// 交给播放器的最终请求：URL 已完成线路选择和代理改写，headers 含播放 UA 与鉴权。
class PlaybackRequest {
  const PlaybackRequest({required this.url, required this.headers, required this.userAgent});

  final Uri url;
  final Map<String, String> headers;
  final String userAgent;
}

/// 服务器章节
class ServerChapter {
  const ServerChapter({required this.name, required this.start, this.marker});

  final String name;
  final Duration start;

  /// Emby：IntroStart / IntroEnd / CreditsStart；普通章节为 Chapter 或空
  final String? marker;
}

/// Jellyfin 媒体片段
class ServerMediaSegment {
  const ServerMediaSegment({required this.type, required this.start, required this.end});

  final String type;
  final Duration start;
  final Duration end;
}

class MediaServerException implements Exception {
  const MediaServerException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// 当前进程内记住的"自动选线"结果（serverId → lineId）。
final Map<String, String> _autoLine = {};

/// Emby / Jellyfin 客户端（两者 API 同源，差异见 docs/03-media-servers.md §2）。
class EmbyClient {
  EmbyClient({required this.config, required ServerConfig server, required this.appVersion, this.onServerChanged})
    : _server = server; // ignore: prefer_initializing_formals

  final AppConfig config;
  final String appVersion;

  /// 登录令牌刷新、线路切换后回调，用于持久化
  final void Function(ServerConfig server)? onServerChanged;

  ServerConfig _server;
  ServerConfig get server => _server;

  static const _timeout = Duration(seconds: 15);

  ServerLine get line {
    final lines = _server.lines;
    if (lines.isEmpty) throw const MediaServerException('没有可用线路');
    final wanted = _server.activeLineId ?? _autoLine[_server.id];
    return lines.where((l) => l.id == wanted).firstOrNull ??
        (lines.where((l) => l.latencyMs != null).toList()..sort((a, b) => a.latencyMs!.compareTo(b.latencyMs!)))
            .firstOrNull ??
        lines.first;
  }

  RequestComposer composerFor(ServerLine l) =>
      RequestComposer(config: config, server: _server, line: l, appVersion: appVersion);

  RequestComposer get composer => composerFor(line);

  Dio _dio() => Dio(
    BaseOptions(
      connectTimeout: _timeout,
      receiveTimeout: _timeout,
      sendTimeout: _timeout,
      responseType: ResponseType.json,
      validateStatus: (s) => s != null && s < 500,
    ),
  );

  // ───────────────────────── 测速 / 公开信息 ─────────────────────────

  /// 测一条线路的延迟（3 次取中位数）；不可用返回 null。
  Future<int?> probe(ServerLine l) async {
    final c = composerFor(l);
    final url = c.finalUrl(c.resolve('/System/Info/Public'), RequestKind.api);
    final dio = _dio()..options.connectTimeout = const Duration(seconds: 5);
    final samples = <int>[];
    for (var i = 0; i < 3; i++) {
      final sw = Stopwatch()..start();
      try {
        final r = await dio.getUri<dynamic>(url, options: Options(headers: c.headers(RequestKind.api)));
        if (r.statusCode == 200) samples.add(sw.elapsedMilliseconds);
      } catch (_) {
        break;
      }
    }
    if (samples.isEmpty) return null;
    samples.sort();
    return samples[samples.length ~/ 2];
  }

  /// 并发测速全部线路，更新延迟，并把自动选线指向最快的一条。
  Future<ServerConfig> probeAll() async {
    final results = await Future.wait(_server.lines.map(probe));
    final lines = [
      for (var i = 0; i < _server.lines.length; i++)
        _server.lines[i].copyWith(latencyMs: results[i], clearLatency: results[i] == null),
    ];
    _server = _server.copyWith(lines: lines);
    final best = lines.where((l) => l.latencyMs != null).toList()..sort((a, b) => a.latencyMs!.compareTo(b.latencyMs!));
    if (best.isNotEmpty) _autoLine[_server.id] = best.first.id;
    onServerChanged?.call(_server);
    return _server;
  }

  Future<Map<String, dynamic>> publicInfo() async =>
      (await _request('GET', '/System/Info/Public', auth: false)) as Map<String, dynamic>;

  // ───────────────────────── 登录 ─────────────────────────

  Future<ServerConfig> login() async {
    final c = composer;
    final url = c.finalUrl(c.resolve('/Users/AuthenticateByName'), RequestKind.api);
    final headers = {...c.headers(RequestKind.api)}
      ..remove('X-Emby-Token')
      ..[_server.type == ServerType.emby ? 'X-Emby-Authorization' : 'Authorization'] = c.authorization(
        withToken: false,
      );
    final r = await _dio().postUri<dynamic>(
      url,
      data: {'Username': _server.username, 'Pw': _server.password},
      options: Options(headers: headers, contentType: Headers.jsonContentType),
    );
    if (r.statusCode == 401 || r.statusCode == 403) throw const MediaServerException('用户名或密码错误', statusCode: 401);
    if (r.statusCode != 200 || r.data is! Map) {
      throw MediaServerException('登录失败（HTTP ${r.statusCode}）', statusCode: r.statusCode);
    }
    final data = r.data as Map<String, dynamic>;
    _server = _server.copyWith(
      token: data['AccessToken'] as String?,
      userId: (data['User'] as Map<String, dynamic>?)?['Id'] as String?,
    );
    onServerChanged?.call(_server);
    return _server;
  }

  // ───────────────────────── 通用请求 ─────────────────────────

  /// 发请求：失败时依次尝试其他线路；401 时用保存的密码重新登录一次。
  Future<Object?> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool auth = true,
    bool retried = false,
  }) async {
    if (auth && !_server.loggedIn) await login();
    final candidates = [line, ..._server.lines.where((l) => l.id != line.id)];
    Object? lastError;
    for (final l in candidates) {
      final c = composerFor(l);
      final url = c.finalUrl(c.resolve(path, query), RequestKind.api);
      try {
        final r = await _dio().requestUri<dynamic>(
          url,
          data: body,
          options: Options(method: method, headers: c.headers(RequestKind.api), contentType: Headers.jsonContentType),
        );
        if (l.id != line.id) {
          _autoLine[_server.id] = l.id;
          debugPrint('switched ${_server.name} to line ${l.name}');
        }
        if (r.statusCode == 401 && auth && !retried && _server.password.isNotEmpty) {
          _server = _server.copyWith(clearSession: true);
          await login();
          return await _request(method, path, query: query, body: body, auth: auth, retried: true);
        }
        if (r.statusCode == 401) throw const MediaServerException('登录已失效，请重新登录', statusCode: 401);
        if (r.statusCode != null && r.statusCode! >= 400) {
          throw MediaServerException('服务器返回 HTTP ${r.statusCode}', statusCode: r.statusCode);
        }
        return r.data;
      } on DioException catch (e) {
        lastError = e;
        if (e.type == DioExceptionType.badResponse) break;
        continue; // 连接失败 / 超时：换下一条线路
      }
    }
    throw MediaServerException(_describe(lastError));
  }

  String _describe(Object? e) {
    if (e is DioException) {
      return switch (e.type) {
        DioExceptionType.connectionTimeout || DioExceptionType.receiveTimeout => '连接超时，所有线路都不可用',
        DioExceptionType.connectionError => '无法连接服务器，请检查地址或网络',
        DioExceptionType.badCertificate => '服务器证书无效',
        _ => e.message ?? '网络错误',
      };
    }
    return e?.toString() ?? '未知错误';
  }

  /// 先确保已登录再取用户 ID：路径里的用户 ID 必须在发请求之前拼好
  Future<String> _userId() async {
    if (!_server.loggedIn) await login();
    return _server.userId ?? '';
  }

  static const _fields =
      'PrimaryImageAspectRatio,ProductionYear,PremiereDate,ProviderIds,Overview,Genres,CommunityRating,'
      'OfficialRating,DateCreated,ChildCount,RecursiveItemCount,UserData,OriginalTitle';
  static const _imageQuery = {'EnableImageTypes': 'Primary,Backdrop,Thumb,Logo', 'ImageTypeLimit': '1'};

  // ───────────────────────── 浏览 ─────────────────────────

  Future<List<Library>> libraries() async {
    final data = await _request('GET', '/Users/${await _userId()}/Views') as Map<String, dynamic>;
    return [
      for (final j in (data['Items'] as List? ?? const []).cast<Map<String, dynamic>>())
        if (const {null, 'movies', 'tvshows', 'mixed', 'homevideos', 'boxsets'}.contains(j['CollectionType']))
          Library(
            id: j['Id'] as String,
            name: j['Name'] as String? ?? '',
            collectionType: j['CollectionType'] as String?,
            image: (j['ImageTags'] as Map?)?['Primary'] != null
                ? ImageRef(j['Id'] as String, ImageKind.primary, tag: (j['ImageTags'] as Map)['Primary'] as String?)
                : null,
          ),
    ];
  }

  Future<PagedItems> items({
    String? parentId,
    String types = 'Movie,Series',
    int start = 0,
    int limit = 60,
    String sortBy = 'DateCreated,SortName',
    String sortOrder = 'Descending',
    String? searchTerm,
    DateTime? minDateLastSaved,
    String? filters,
  }) async {
    final data = await _request(
      'GET',
      '/Users/${await _userId()}/Items',
      query: {
        'ParentId': ?parentId,
        'Recursive': 'true',
        'IncludeItemTypes': types,
        'StartIndex': '$start',
        'Limit': '$limit',
        'SortBy': sortBy,
        'SortOrder': sortOrder,
        'Fields': _fields,
        'SearchTerm': ?searchTerm,
        'MinDateLastSaved': ?minDateLastSaved?.toUtc().toIso8601String(),
        'Filters': ?filters,
        ..._imageQuery,
      },
    ) as Map<String, dynamic>;
    final list = (data['Items'] as List? ?? const []).cast<Map<String, dynamic>>();
    return PagedItems(list.map(parseItem).toList(), data['TotalRecordCount'] as int? ?? list.length);
  }

  Future<List<MediaItem>> latest({String? parentId, int limit = 20}) async {
    final data = await _request(
      'GET',
      '/Users/${await _userId()}/Items/Latest',
      query: {'ParentId': ?parentId, 'Limit': '$limit', 'Fields': _fields, ..._imageQuery},
    );
    return (data as List? ?? const []).cast<Map<String, dynamic>>().map(parseItem).toList();
  }

  Future<List<MediaItem>> resume({int limit = 20}) async {
    final data = await _request(
      'GET',
      '/Users/${await _userId()}/Items/Resume',
      query: {'Limit': '$limit', 'MediaTypes': 'Video', 'Fields': _fields, ..._imageQuery},
    ) as Map<String, dynamic>;
    return (data['Items'] as List? ?? const []).cast<Map<String, dynamic>>().map(parseItem).toList();
  }

  Future<MediaItem> item(String id) async => parseItem(
    await _request('GET', '/Users/${await _userId()}/Items/$id', query: {'Fields': _fields}) as Map<String, dynamic>,
  );

  /// 章节列表（片头片尾：Emby 4.8+ 的章节带 MarkerType：IntroStart / IntroEnd / CreditsStart）
  Future<List<ServerChapter>> chapters(String itemId) async {
    final j = await _request(
      'GET',
      '/Users/${await _userId()}/Items/$itemId',
      query: {'Fields': 'Chapters'},
    ) as Map<String, dynamic>;
    return [
      for (final c in (j['Chapters'] as List? ?? const []).cast<Map<String, dynamic>>())
        ServerChapter(
          name: c['Name'] as String? ?? '',
          start: ticksToDuration(c['StartPositionTicks'] as num?),
          marker: c['MarkerType'] as String?,
        ),
    ];
  }

  /// Jellyfin 10.10+ 的媒体片段（Intro / Outro / Recap / Preview / Commercial）。Emby 或旧版本返回空列表。
  Future<List<ServerMediaSegment>> mediaSegments(String itemId) async {
    if (_server.type != ServerType.jellyfin) return const [];
    try {
      final j = await _request('GET', '/MediaSegments/$itemId') as Map<String, dynamic>;
      return [
        for (final s in (j['Items'] as List? ?? const []).cast<Map<String, dynamic>>())
          ServerMediaSegment(
            type: s['Type'] as String? ?? '',
            start: ticksToDuration(s['StartTicks'] as num?),
            end: ticksToDuration(s['EndTicks'] as num?),
          ),
      ];
    } on MediaServerException catch (e) {
      // 旧版 Jellyfin 没有这个接口
      if (e.statusCode == 404 || e.statusCode == 400) return const [];
      rethrow;
    }
  }

  Future<List<MediaItem>> seasons(String seriesId) async {
    final data = await _request(
      'GET',
      '/Shows/$seriesId/Seasons',
      query: {'UserId': await _userId(), 'Fields': _fields},
    ) as Map<String, dynamic>;
    return (data['Items'] as List? ?? const []).cast<Map<String, dynamic>>().map(parseItem).toList();
  }

  Future<List<MediaItem>> episodes(String seriesId, {String? seasonId}) async {
    final data = await _request(
      'GET',
      '/Shows/$seriesId/Episodes',
      query: {'UserId': await _userId(), 'SeasonId': ?seasonId, 'Fields': _fields, ..._imageQuery},
    ) as Map<String, dynamic>;
    return (data['Items'] as List? ?? const []).cast<Map<String, dynamic>>().map(parseItem).toList();
  }

  /// 剧集"下一集"（继续看哪一集）
  Future<MediaItem?> nextUp(String seriesId) async {
    final data = await _request(
      'GET',
      '/Shows/NextUp',
      query: {'UserId': await _userId(), 'SeriesId': seriesId, 'Fields': _fields},
    ) as Map<String, dynamic>;
    final list = (data['Items'] as List? ?? const []).cast<Map<String, dynamic>>();
    return list.isEmpty ? null : parseItem(list.first);
  }

  Future<({int movies, int series})> counts() async {
    final data = await _request('GET', '/Items/Counts', query: {'UserId': await _userId()}) as Map<String, dynamic>;
    return (movies: data['MovieCount'] as int? ?? 0, series: data['SeriesCount'] as int? ?? 0);
  }

  // ───────────────────────── 播放 ─────────────────────────

  Future<({List<MediaSourceInfo> sources, String? playSessionId})> playbackInfo(String itemId) async {
    final data = await _request(
      'POST',
      '/Items/$itemId/PlaybackInfo',
      query: {'UserId': await _userId(), 'IsPlayback': 'true', 'AutoOpenLiveStream': 'true'},
      body: {'UserId': await _userId()},
    ) as Map<String, dynamic>;
    final sources = [
      for (final s in (data['MediaSources'] as List? ?? const []).cast<Map<String, dynamic>>()) parseSource(itemId, s),
    ];
    return (sources: sources, playSessionId: data['PlaySessionId'] as String?);
  }

  /// 直接播放（Static=true，不转码）的请求。
  PlaybackRequest stream(MediaSourceInfo source, {String? playSessionId}) {
    final c = composer;
    final container = source.container.split(',').first.trim();
    final original = c.resolve('/Videos/${source.itemId}/stream${container.isEmpty ? '' : '.$container'}', {
      'Static': 'true',
      'MediaSourceId': source.id,
      'PlaySessionId': ?playSessionId,
      'DeviceId': '${config.deviceId}-${_server.id}',
      'api_key': ?_server.token,
    });
    final headers = c.headers(RequestKind.stream);
    return PlaybackRequest(
      url: c.finalUrl(original, RequestKind.stream),
      headers: headers,
      userAgent: headers['User-Agent']!,
    );
  }

  /// 外挂字幕地址
  PlaybackRequest? subtitle(MediaSourceInfo source, MediaStreamInfo stream) {
    final delivery = stream.deliveryUrl;
    if (delivery == null || delivery.isEmpty) return null;
    final c = composer;
    final base = c.apiBase;
    final original = delivery.startsWith('http')
        ? Uri.parse(delivery)
        : base.replace(path: '${base.path}${delivery.split('?').first}', query: delivery.split('?').skip(1).join('?'));
    final headers = c.headers(RequestKind.stream);
    return PlaybackRequest(
      url: c.finalUrl(original, RequestKind.stream),
      headers: headers,
      userAgent: headers['User-Agent']!,
    );
  }

  Future<void> reportStart(MediaSourceInfo s, Duration position, String? playSessionId) =>
      _report('/Sessions/Playing', s, position, playSessionId);

  Future<void> reportProgress(
    MediaSourceInfo s,
    Duration position,
    String? playSessionId, {
    bool paused = false,
    String event = 'TimeUpdate',
  }) => _report('/Sessions/Playing/Progress', s, position, playSessionId, paused: paused, event: event);

  Future<void> reportStopped(MediaSourceInfo s, Duration position, String? playSessionId) =>
      _report('/Sessions/Playing/Stopped', s, position, playSessionId);

  Future<void> _report(
    String path,
    MediaSourceInfo s,
    Duration position,
    String? playSessionId, {
    bool paused = false,
    String? event,
  }) async {
    try {
      await _request(
        'POST',
        path,
        body: {
          'ItemId': s.itemId,
          'MediaSourceId': s.id,
          'PlaySessionId': ?playSessionId,
          'PositionTicks': durationToTicks(position),
          'CanSeek': true,
          'IsPaused': paused,
          'PlayMethod': 'DirectPlay',
          'EventName': ?event,
        },
      );
    } catch (e) {
      debugPrint('report $path failed: $e');
    }
  }

  Future<void> setPlayed(String itemId, bool played) async =>
      _request(played ? 'POST' : 'DELETE', '/Users/${await _userId()}/PlayedItems/$itemId');

  Future<void> setFavorite(String itemId, bool favorite) async =>
      _request(favorite ? 'POST' : 'DELETE', '/Users/${await _userId()}/FavoriteItems/$itemId');

  // ───────────────────────── 图片 ─────────────────────────

  ({Uri url, Map<String, String> headers}) image(ImageRef ref, {int maxWidth = 440}) {
    final c = composer;
    final kind = switch (ref.kind) {
      ImageKind.primary => 'Primary',
      ImageKind.backdrop => 'Backdrop/${ref.index}',
      ImageKind.thumb => 'Thumb',
      ImageKind.logo => 'Logo',
    };
    final original = c.resolve('/Items/${ref.itemId}/Images/$kind', {
      'maxWidth': '$maxWidth',
      'quality': '90',
      'tag': ?ref.tag,
    });
    return (url: c.finalUrl(original, RequestKind.image), headers: {'User-Agent': c.userAgentFor(RequestKind.image)});
  }

  // ───────────────────────── 解析 ─────────────────────────

  MediaItem parseItem(Map<String, dynamic> j) {
    final id = j['Id'] as String;
    final tags = (j['ImageTags'] as Map?)?.cast<String, dynamic>() ?? const {};
    final backdrops = (j['BackdropImageTags'] as List?)?.cast<String>() ?? const [];
    final parentBackdrops = (j['ParentBackdropImageTags'] as List?)?.cast<String>() ?? const [];
    final user = (j['UserData'] as Map?)?.cast<String, dynamic>() ?? const {};
    final providers = (j['ProviderIds'] as Map?)?.cast<String, dynamic>() ?? const {};
    final premiere = DateTime.tryParse(j['PremiereDate'] as String? ?? '');

    ImageRef? primary;
    if (tags['Primary'] != null) {
      primary = ImageRef(id, ImageKind.primary, tag: tags['Primary'] as String);
    } else if (j['SeriesPrimaryImageTag'] != null && j['SeriesId'] != null) {
      primary = ImageRef(j['SeriesId'] as String, ImageKind.primary, tag: j['SeriesPrimaryImageTag'] as String);
    }
    ImageRef? backdrop;
    if (backdrops.isNotEmpty) {
      backdrop = ImageRef(id, ImageKind.backdrop, tag: backdrops.first);
    } else if (parentBackdrops.isNotEmpty && j['ParentBackdropItemId'] != null) {
      backdrop = ImageRef(j['ParentBackdropItemId'] as String, ImageKind.backdrop, tag: parentBackdrops.first);
    }
    ImageRef? thumb;
    if (tags['Thumb'] != null) {
      thumb = ImageRef(id, ImageKind.thumb, tag: tags['Thumb'] as String);
    } else if (j['ParentThumbItemId'] != null && j['ParentThumbImageTag'] != null) {
      thumb = ImageRef(j['ParentThumbItemId'] as String, ImageKind.thumb, tag: j['ParentThumbImageTag'] as String);
    }
    ImageRef? logo;
    if (tags['Logo'] != null) {
      logo = ImageRef(id, ImageKind.logo, tag: tags['Logo'] as String);
    } else if (j['ParentLogoItemId'] != null && j['ParentLogoImageTag'] != null) {
      logo = ImageRef(j['ParentLogoItemId'] as String, ImageKind.logo, tag: j['ParentLogoImageTag'] as String);
    }

    return MediaItem(
      serverId: _server.id,
      id: id,
      kind: MediaKind.fromEmby(j['Type'] as String?),
      name: j['Type'] == 'Season'
          ? localizeSeasonName(j['Name'] as String? ?? '', j['IndexNumber'] as int?)
          : j['Name'] as String? ?? '',
      originalTitle: j['OriginalTitle'] as String?,
      overview: j['Overview'] as String?,
      year: j['ProductionYear'] as int? ?? premiere?.year,
      premiereDate: premiere,
      rating: (j['CommunityRating'] as num?)?.toDouble(),
      officialRating: j['OfficialRating'] as String?,
      genres: [for (final g in (j['Genres'] as List?)?.cast<String>() ?? const <String>[]) translateGenre(g)],
      runtime: j['RunTimeTicks'] == null ? null : ticksToDuration(j['RunTimeTicks'] as num),
      tmdbId: (providers['Tmdb'] ?? providers['tmdb'])?.toString(),
      imdbId: (providers['Imdb'] ?? providers['imdb'])?.toString(),
      tvdbId: (providers['Tvdb'] ?? providers['tvdb'])?.toString(),
      primary: primary,
      backdrop: backdrop,
      thumb: thumb,
      logo: logo,
      seriesId: j['SeriesId'] as String?,
      seriesName: j['SeriesName'] as String?,
      seasonId: j['SeasonId'] as String?,
      seasonNumber: j['ParentIndexNumber'] as int? ?? (j['Type'] == 'Season' ? j['IndexNumber'] as int? : null),
      episodeNumber: j['Type'] == 'Episode' ? j['IndexNumber'] as int? : null,
      childCount: j['ChildCount'] as int? ?? j['RecursiveItemCount'] as int?,
      played: user['Played'] as bool? ?? false,
      favorite: user['IsFavorite'] as bool? ?? false,
      position: ticksToDuration(user['PlaybackPositionTicks'] as num?),
      playedPercentage: (user['PlayedPercentage'] as num?)?.toDouble(),
      dateCreated: DateTime.tryParse(j['DateCreated'] as String? ?? ''),
      lastPlayed: DateTime.tryParse(user['LastPlayedDate'] as String? ?? ''),
    );
  }

  MediaSourceInfo parseSource(String itemId, Map<String, dynamic> s) {
    final streams = <MediaStreamInfo>[];
    for (final m in (s['MediaStreams'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final rangeType = (m['VideoRangeType'] ?? m['VideoRange'] ?? '').toString().toLowerCase();
      final range = rangeType.contains('dovi') || rangeType.contains('dolby')
          ? VideoRange.dolbyVision
          : rangeType.contains('hdr10plus') || rangeType.contains('hdr10+')
          ? VideoRange.hdr10Plus
          : rangeType.contains('hlg')
          ? VideoRange.hlg
          : rangeType.contains('hdr')
          ? VideoRange.hdr10
          : VideoRange.sdr;
      streams.add(
        MediaStreamInfo(
          index: m['Index'] as int? ?? 0,
          type: m['Type'] as String? ?? '',
          codec: m['Codec'] as String?,
          language: m['Language'] as String?,
          title: (m['DisplayTitle'] ?? m['Title']) as String?,
          isDefault: m['IsDefault'] as bool? ?? false,
          isExternal: m['IsExternal'] as bool? ?? false,
          channels: m['Channels'] as int?,
          width: m['Width'] as int?,
          height: m['Height'] as int?,
          bitDepth: m['BitDepth'] as int?,
          frameRate: ((m['RealFrameRate'] ?? m['AverageFrameRate']) as num?)?.toDouble(),
          range: range,
          deliveryUrl: m['DeliveryUrl'] as String?,
        ),
      );
    }
    return MediaSourceInfo(
      serverId: _server.id,
      itemId: itemId,
      id: s['Id'] as String,
      container: s['Container'] as String? ?? '',
      name: s['Name'] as String?,
      size: (s['Size'] as num?)?.toInt(),
      bitrate: (s['Bitrate'] as num?)?.toInt(),
      duration: s['RunTimeTicks'] == null ? null : ticksToDuration(s['RunTimeTicks'] as num),
      streams: streams,
      isRemote: s['IsRemote'] as bool? ?? false,
    );
  }
}

/// 播放会话 ID（服务器未返回时本地生成）
String newPlaySessionId() => List.generate(16, (_) => Random().nextInt(16).toRadixString(16)).join();
