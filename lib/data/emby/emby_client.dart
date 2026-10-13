import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/log/load_metrics.dart';
import '../cache/account_scope.dart';

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

/// 登录被拒时给用户看的原因：不是所有 401 / 403 都是密码错了
@visibleForTesting
String loginRejectedMessage(int status, Object? body, String where) {
  final text = switch (body) {
    final Map<String, dynamic> m => '${m['error'] ?? m['message'] ?? m['Message'] ?? ''}',
    final String s => s,
    _ => '',
  }.trim();
  final lower = text.toLowerCase();
  if (lower.contains('device') && (lower.contains('limit') || lower.contains('exceed') || lower.contains('max'))) {
    return '这个账号的设备数已达上限（$where：$text）。请在其他设备上退出登录，或请服主清理旧设备后再试';
  }
  // 网关 / Nginx / Cloudflare 的拦截页（HTML），或网关自己的 JSON 错误：通常是限制了播放器 UA 或 IP
  if (status == 403 && (lower.contains('<html') || lower.contains('forbidden') || lower.contains('access denied'))) {
    return '服务器拒绝了这个客户端（$where）。可能只允许特定播放器：在「播放 UA」里填写能正常使用的播放器 UA 后再试';
  }
  if (status == 401 || lower.contains('password') || lower.contains('invalid user')) {
    return '用户名或密码错误（$where）';
  }
  final detail = text.isEmpty || text.length > 120 || lower.contains('<') ? '' : '：$text';
  return '服务器拒绝登录（$where$detail）';
}

/// 当前进程内记住的"自动选线"结果（serverId → lineId）。
final Map<String, String> _autoLine = {};

/// Emby / Jellyfin 客户端（两者 API 同源，差异见 docs/03-media-servers.md §2）。
class EmbyClient {
  EmbyClient({required this.config, required ServerConfig server, required this.appVersion, this.onServerChanged})
    : _server = server,
      _metricsId = accountScope(server).substring(0, 10); // ignore: prefer_initializing_formals

  final AppConfig config;
  final String appVersion;

  /// 登录令牌刷新、线路切换后回调，用于持久化
  final void Function(ServerConfig server)? onServerChanged;

  ServerConfig _server;
  final String _metricsId;
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
        final r = await LoadTrace.request(
          'media_api',
          _metricsId,
          () => dio.getUri<dynamic>(url, options: Options(headers: c.headers(RequestKind.api))),
          isSuccess: (r) => (r.statusCode ?? 500) < 400,
        );
        // 401 / 403 也算连得上：按 UA 白名单拦截的服务器到登录时再提示原因，不要报"连不上"
        final code = r.statusCode ?? 0;
        if (code >= 200 && code < 500 && code != 404) samples.add(sw.elapsedMilliseconds);
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
    try {
      return await _login(_server.password);
    } on MediaServerException catch (e) {
      // 电视屏幕键盘有时会在密码前后带上空格：去掉空格再试一次
      final trimmed = _server.password.trim();
      if (e.statusCode == 401 && trimmed != _server.password) {
        await _login(trimmed);
        _server = _server.copyWith(password: trimmed);
        onServerChanged?.call(_server);
        return _server;
      }
      rethrow;
    }
  }

  Future<ServerConfig> _login(String password) async {
    final c = composer;
    final url = c.finalUrl(c.resolve('/Users/AuthenticateByName'), RequestKind.api);
    final headers = {...c.headers(RequestKind.api)}
      ..remove('X-Emby-Token')
      ..[_server.type == ServerType.emby ? 'X-Emby-Authorization' : 'Authorization'] = c.authorization(
        withToken: false,
      );
    final r = await LoadTrace.request(
      'media_api',
      _metricsId,
      () => _dio().postUri<dynamic>(
        url,
        data: {'Username': _server.username, 'Pw': password},
        options: Options(headers: headers, contentType: Headers.jsonContentType),
      ),
      isSuccess: (r) => (r.statusCode ?? 500) < 400,
    );
    if (r.statusCode == 401 || r.statusCode == 403) {
      // 说明是哪个地址、是否经过反向代理拒绝的，方便排查（内网地址、代理、账号大小写等）
      final via = c.usesProxy(RequestKind.api) ? '，经反向代理' : '';
      final where = '${c.apiBase.host}${c.apiBase.hasPort ? ':${c.apiBase.port}' : ''}$via 返回 HTTP ${r.statusCode}';
      throw MediaServerException(loginRejectedMessage(r.statusCode!, r.data, where), statusCode: 401);
    }
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
        final r = await LoadTrace.request(
          'media_api',
          _metricsId,
          () => _dio().requestUri<dynamic>(
            url,
            data: body,
            options: Options(method: method, headers: c.headers(RequestKind.api), contentType: Headers.jsonContentType),
          ),
          isSuccess: (r) => (r.statusCode ?? 500) < 400,
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

  // 不请求 RecursiveItemCount / PrimaryImageAspectRatio：Emby 要为每部剧递归统计、读取图片尺寸，列表一长 NAS 负载很高
  static const _fields =
      'ProductionYear,PremiereDate,ProviderIds,Overview,Genres,CommunityRating,'
      'OfficialRating,DateCreated,ChildCount,UserData,OriginalTitle,CriticRating';

  /// Emby 4.8 起列表接口默认不返回 UserData 里的上次播放时间 / 播放次数，要在 Fields 里明确要求
  /// （Emby 网页端也是这样请求的）。Jellyfin 默认就返回。
  String get _userFields =>
      _server.type == ServerType.emby ? '$_fields,UserDataPlayCount,UserDataLastPlayedDate' : _fields;

  /// 聚合索引用的精简字段：不要用户数据（播放进度等），服务器不用逐条查用户状态
  static const indexFields =
      'ProductionYear,PremiereDate,ProviderIds,Overview,Genres,CommunityRating,DateCreated,DateLastMediaAdded,'
      'OriginalTitle,OfficialRating';

  /// 儿童模式：让服务器按分级过滤（Emby / Jellyfin 都支持 MaxOfficialRating），本地再按分级二次过滤
  Map<String, String> get _parentalQuery =>
      config.parental.enabled ? {'MaxOfficialRating': config.parental.maxOfficialRating} : const {};

  Iterable<MediaItem> _allowed(Iterable<MediaItem> items) => config.parental.enabled
      ? items.where((it) => it.kind == MediaKind.episode || config.parental.allows(it.officialRating))
      : items;

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
    String? fields,
    bool userData = true,
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
        'Fields': fields ?? _userFields,
        if (!userData) 'EnableUserData': 'false',
        'SearchTerm': ?searchTerm,
        'MinDateLastSaved': ?minDateLastSaved?.toUtc().toIso8601String(),
        'Filters': ?filters,
        ..._parentalQuery,
        ..._imageQuery,
      },
    ) as Map<String, dynamic>;
    final list = _pageItems(data);
    final total = data['TotalRecordCount'] as int?;
    if (total != null && (total < 0 || total < list.length)) throw const MediaServerException('服务器条目总数无效');
    return PagedItems(
      _allowed(list.map(parseItem)).toList(),
      total ?? list.length,
      rawCount: list.length,
      totalKnown: total != null,
    );
  }

  /// 成功响应也必须有合法列表，不能把错误 JSON / 缺失 Items 当作确定的空结果。
  List<Map<String, dynamic>> _pageItems(Map<String, dynamic> data) {
    if (data['Items'] is! List) throw const MediaServerException('服务器列表响应不完整');
    final list = (data['Items'] as List).cast<Map<String, dynamic>>();
    if (list.any((j) => j['Id'] is! String || (j['Id'] as String).isEmpty)) {
      throw const MediaServerException('服务器列表条目无效');
    }
    return list;
  }

  Future<List<MediaItem>> latest({String? parentId, int limit = 20}) async {
    final data = await _request(
      'GET',
      '/Users/${await _userId()}/Items/Latest',
      query: {'ParentId': ?parentId, 'Limit': '$limit', 'Fields': _userFields, ..._parentalQuery, ..._imageQuery},
    );
    return _allowed((data as List? ?? const []).cast<Map<String, dynamic>>().map(parseItem)).toList();
  }

  Future<List<MediaItem>> resume({int limit = 20}) async {
    final data = await _request(
      'GET',
      '/Users/${await _userId()}/Items/Resume',
      query: {'Limit': '$limit', 'MediaTypes': 'Video', 'Fields': _userFields, ..._parentalQuery, ..._imageQuery},
    ) as Map<String, dynamic>;
    final list = _pageItems(data);
    if (list.isEmpty && (data['TotalRecordCount'] as num? ?? 0) > 0) {
      throw const MediaServerException('服务器继续观看响应不完整');
    }
    return _allowed(list.map(parseItem)).toList();
  }

  Future<MediaItem> item(String id) async => parseItem(
    await _request('GET', '/Users/${await _userId()}/Items/$id', query: {'Fields': _userFields})
        as Map<String, dynamic>,
  );

  /// 当前用户的头像（没有头像时服务器返回 404，界面显示首字母）
  ({Uri url, Map<String, String> headers})? userImage({int maxWidth = 160}) {
    final uid = _server.userId;
    if (uid == null) return null;
    final c = composer;
    final original = c.resolve('/Users/$uid/Images/Primary', {'maxWidth': '$maxWidth', 'quality': '90'});
    return (url: c.finalUrl(original, RequestKind.image), headers: c.headers(RequestKind.image));
  }

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
      query: {'UserId': await _userId(), 'Fields': _userFields},
    ) as Map<String, dynamic>;
    return (data['Items'] as List? ?? const []).cast<Map<String, dynamic>>().map(parseItem).toList();
  }

  Future<List<MediaItem>> episodes(String seriesId, {String? seasonId}) async {
    final data = await _request(
      'GET',
      '/Shows/$seriesId/Episodes',
      query: {'UserId': await _userId(), 'SeasonId': ?seasonId, 'Fields': _userFields, ..._imageQuery},
    ) as Map<String, dynamic>;
    return (data['Items'] as List? ?? const []).cast<Map<String, dynamic>>().map(parseItem).toList();
  }

  /// 剧集"下一集"（继续看哪一集）
  Future<MediaItem?> nextUp(String seriesId) async {
    final data = await _request(
      'GET',
      '/Shows/NextUp',
      query: {'UserId': await _userId(), 'SeriesId': seriesId, 'Fields': _userFields},
    ) as Map<String, dynamic>;
    final list = (data['Items'] as List? ?? const []).cast<Map<String, dynamic>>();
    return list.isEmpty ? null : parseItem(list.first);
  }

  Future<({int movies, int series})> counts() async {
    final data = await _request('GET', '/Items/Counts', query: {'UserId': await _userId()}) as Map<String, dynamic>;
    return (movies: data['MovieCount'] as int? ?? 0, series: data['SeriesCount'] as int? ?? 0);
  }

  // ───────────────────────── 播放 ─────────────────────────

  /// [isPlayback]：真正开始播放时为 true；详情页列资源 / 预加载时为 false，服务器不用为此准备播放会话
  Future<({List<MediaSourceInfo> sources, String? playSessionId})> playbackInfo(
    String itemId, {
    bool isPlayback = true,
  }) async {
    final data = await _request(
      'POST',
      '/Items/$itemId/PlaybackInfo',
      query: {'UserId': await _userId(), 'IsPlayback': '$isPlayback', 'AutoOpenLiveStream': '$isPlayback'},
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
    final c = composer;
    final base = c.apiBase;
    var delivery = stream.deliveryUrl;
    if (delivery == null || delivery.isEmpty) {
      // 服务器没给投递地址时按标准路径取（Emby / Jellyfin 通用）
      if (!stream.isExternal) return null;
      final ext = switch ((stream.codec ?? '').toLowerCase()) {
        'subrip' || '' => 'srt',
        final c => c,
      };
      delivery = '/Videos/${source.itemId}/${source.id}/Subtitles/${stream.index}/Stream.$ext';
    }
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

  // ───────────────────────── 在线字幕 ─────────────────────────

  /// 让服务器用它配置的字幕插件（如 OpenSubtitles）在线搜索字幕；[language] 为三字母代码，如 chi / eng
  Future<List<RemoteSubtitle>> searchSubtitles(String itemId, String language) async {
    final data = await _request('GET', '/Items/$itemId/RemoteSearch/Subtitles/$language');
    return [
      for (final j in (data as List? ?? const []).whereType<Map<String, dynamic>>())
        RemoteSubtitle(
          id: j['Id']?.toString() ?? '',
          name: j['Name']?.toString() ?? '',
          provider: j['ProviderName']?.toString() ?? '',
          format: j['Format']?.toString(),
          language: j['ThreeLetterISOLanguageName']?.toString() ?? j['Language']?.toString(),
          downloads: (j['DownloadCount'] as num?)?.toInt(),
          rating: (j['CommunityRating'] as num?)?.toDouble(),
        ),
    ]..sort((a, b) => (b.downloads ?? 0).compareTo(a.downloads ?? 0));
  }

  /// 服务器下载这条字幕并保存在视频旁边，之后作为外挂字幕出现在播放信息里
  Future<void> downloadSubtitle(String itemId, String subtitleId) async {
    await _request('POST', '/Items/$itemId/RemoteSearch/Subtitles/${Uri.encodeComponent(subtitleId)}');
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
      criticRating: (j['CriticRating'] as num?)?.toDouble(),
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
      childCount: j['ChildCount'] as int?,
      played: user['Played'] as bool? ?? false,
      favorite: user['IsFavorite'] as bool? ?? false,
      position: ticksToDuration(user['PlaybackPositionTicks'] as num?),
      playedPercentage: (user['PlayedPercentage'] as num?)?.toDouble(),
      dateCreated: DateTime.tryParse(j['DateCreated'] as String? ?? ''),
      lastMediaAdded: DateTime.tryParse(j['DateLastMediaAdded'] as String? ?? ''),
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
          streamTitle: m['Title'] as String?,
          profile: m['Profile'] as String?,
          level: (m['Level'] as num?)?.toDouble(),
          colorPrimaries: m['ColorPrimaries'] as String?,
          colorSpace: m['ColorSpace'] as String?,
          colorTransfer: m['ColorTransfer'] as String?,
          channelLayout: m['ChannelLayout'] as String?,
          sampleRate: (m['SampleRate'] as num?)?.toInt(),
          bitrate: (m['BitRate'] as num?)?.toInt(),
          aspectRatio: m['AspectRatio'] as String?,
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

/// 服务器在线搜到的字幕
class RemoteSubtitle {
  const RemoteSubtitle({
    required this.id,
    required this.name,
    required this.provider,
    this.format,
    this.language,
    this.downloads,
    this.rating,
  });

  final String id;
  final String name;
  final String provider;
  final String? format;
  final String? language;
  final int? downloads;
  final double? rating;
}
