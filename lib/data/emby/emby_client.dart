import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException, HttpException, SocketException;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/log/load_metrics.dart';
import '../../player/trickplay.dart';
import '../cache/account_scope.dart';

import '../config/app_config.dart';
import '../media/media_models.dart';
import '../media/series_ratings.dart';
import '../media/zh.dart';
import '../net/request_composer.dart';
import '../subtitles/online_subtitles.dart' show SubtitleFile, saveSubtitleFile;

part '../fnos/fnos_client.dart';
part '../plex/plex_client.dart';

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

/// 服务器返回 5xx 时给用户看的说明（不显示 Dio 的英文原文）
String describeServerError(int? status) => switch (status) {
  502 || 503 || 504 => '服务器暂时无法响应（HTTP $status）：媒体服务器或它前面的反向代理出错，稍后重试；一直这样请检查服务器',
  null => '服务器出错',
  _ => '服务器处理请求时出错（HTTP $status），请检查服务器日志',
};

class MediaServerException implements Exception {
  const MediaServerException(this.message, {this.statusCode, this.connectionFailure = false});

  final String message;
  final int? statusCode;
  final bool connectionFailure;

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
/// Plex、飞牛影视用子类 [PlexClient]、[FnosClient]（同一个库，复用线路、测速、重新登录与上报队列），用 [mediaServerClient] 按类型创建。
class EmbyClient {
  EmbyClient({
    required this.config,
    required ServerConfig server,
    required this.appVersion,
    this.onServerChanged,
    this.onProbed,
  }) : _server = server,
       _metricsId = accountScope(server).substring(0, 10); // ignore: prefer_initializing_formals

  final AppConfig config;
  final String appVersion;

  /// 登录令牌刷新、线路切换后回调，用于持久化
  final void Function(ServerConfig server)? onServerChanged;
  final void Function(bool reachable)? onProbed;

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

  /// 每个接口请求用一个新连接，用完关掉（v0.15.28–v0.15.34 曾改为复用连接，
  /// 但反向代理 / 服务器会在客户端不知道的情况下关掉闲置连接，复用到这种连接时请求失败，改回每次新建）
  static Future<T> _once<T>(Future<T> Function(Dio dio) send) async {
    final dio = _dio();
    try {
      return await send(dio);
    } finally {
      dio.close();
    }
  }

  static Dio _dio() => Dio(
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
  Future<int?> probe(ServerLine l, {Duration? timeout}) async {
    final c = composerFor(l);
    final url = c.finalUrl(c.resolve(_probePath), RequestKind.api);
    final dio = _dio()..options.connectTimeout = const Duration(seconds: 5);
    final elapsed = Stopwatch()..start();
    final samples = <int>[];
    try {
      for (var i = 0; i < 3; i++) {
        final remaining = timeout == null ? null : timeout - elapsed.elapsed;
        if (remaining != null && remaining <= Duration.zero) break;
        final sw = Stopwatch()..start();
        try {
          final r = await LoadTrace.request('media_api', _metricsId, () {
            final request = dio.getUri<dynamic>(url, options: Options(headers: c.headers(RequestKind.api)));
            return remaining == null ? request : request.timeout(remaining);
          }, isSuccess: (r) => (r.statusCode ?? 500) < 400);
          // 401 / 403 也算连得上：按 UA 白名单拦截的服务器到登录时再提示原因，不要报"连不上"
          final code = r.statusCode ?? 0;
          if (code >= 200 && code < 500 && code != 404) samples.add(sw.elapsedMilliseconds);
        } catch (_) {
          break;
        }
      }
    } finally {
      dio.close(force: true);
    }
    if (samples.isEmpty) return null;
    samples.sort();
    return samples[samples.length ~/ 2];
  }

  /// 并发测速全部线路，更新延迟，并把自动选线指向最快的一条。
  /// [notify] 为 false 时不回调 [onServerChanged]（调用方把多台服务器的结果合并成一次保存）
  Future<ServerConfig> probeAll({bool notify = true, Duration? timeout}) async {
    final results = await Future.wait(_server.lines.map((line) => probe(line, timeout: timeout)));
    await _dropLinesRejectingLogin(results, timeout: timeout);
    final lines = [
      for (var i = 0; i < _server.lines.length; i++)
        _server.lines[i].copyWith(latencyMs: results[i], clearLatency: results[i] == null),
    ];
    _server = _server.copyWith(lines: lines);
    final best = lines.where((l) => l.latencyMs != null).toList()..sort((a, b) => a.latencyMs!.compareTo(b.latencyMs!));
    if (best.isNotEmpty) _autoLine[_server.id] = best.first.id;
    if (notify) {
      onProbed?.call(best.isNotEmpty);
      onServerChanged?.call(_server);
    }
    return _server;
  }

  /// 测速用的免登录接口
  String get _probePath => '/System/Info/Public';

  /// 免登录接口通了不代表能用：有的线路（反代只转发了部分路径、按 UA / 地区拦截、返回网页登录页）
  /// 测速通过却登录不上、取不到数据。已登录的服务器（Emby / Jellyfin / Plex / 飞牛同一套规则）再用登录令牌
  /// 读一次需要登录的接口，读不到的线路（被拒、返回的不是数据、超时、网络出错）都当成不可用。
  /// 所有线路都读不到时先用保存的密码重新登录一次再验；登录失败或仍然读不到，就和连不上一样（红点）
  Future<void> _dropLinesRejectingLogin(List<int?> latency, {Duration? timeout}) async {
    if (!_server.loggedIn || latency.every((l) => l == null)) return;
    final limit = timeout ?? const Duration(seconds: 8);
    Future<List<bool>> check() => Future.wait([
      for (var i = 0; i < _server.lines.length; i++)
        latency[i] == null ? Future.value(false) : _authCheck(_server.lines[i], timeout: limit),
    ]);
    var ok = await check();
    if (!ok.contains(true)) {
      // 重新登录走这次测速最快的线路（之前自动选的线路可能已经连不上了）；用户手动指定的线路不动
      var fastest = -1;
      for (var i = 0; i < latency.length; i++) {
        if (latency[i] != null && (fastest < 0 || latency[i]! < latency[fastest]!)) fastest = i;
      }
      _autoLine[_server.id] = _server.lines[fastest].id;
      try {
        await login().timeout(limit + const Duration(seconds: 5));
        ok = await check();
      } catch (e) {
        debugPrint('probe: ${_server.displayName} 所有线路都读不到数据，重新登录也失败：$e');
      }
    }
    for (var i = 0; i < latency.length; i++) {
      if (latency[i] != null && !ok[i]) {
        debugPrint('probe: ${_server.displayName} · ${_server.lines[i].name} 测速通过但用登录令牌读不到数据，当作不可用');
        latency[i] = null;
      }
    }
  }

  /// 验证登录用的接口：Emby / Jellyfin 读当前用户
  String get _authProbePath => '/Users/${_server.userId}';

  /// 验证接口的响应算不算读到了数据
  bool _authProbeOk(Object? data) => data is Map;

  /// 用登录令牌通过这条线路读 [_authProbePath]：读到数据才算能用；被拒、网页、超时、网络出错都算不能用
  Future<bool> _authCheck(ServerLine l, {required Duration timeout}) async {
    final c = composerFor(l);
    final path = _authProbePath;
    final url = c.finalUrl(c.resolve(path), RequestKind.api);
    final dio = _dio()..options.connectTimeout = const Duration(seconds: 5);
    try {
      final request = dio.getUri<dynamic>(
        url,
        options: Options(headers: {...c.headers(RequestKind.api), ..._signedHeaders('GET', path, null, null)}),
      );
      final r = await request.timeout(timeout);
      final code = r.statusCode ?? 0;
      return code >= 200 && code < 300 && _authProbeOk(r.data);
    } catch (_) {
      return false;
    } finally {
      dio.close(force: true);
    }
  }

  Future<Map<String, dynamic>> publicInfo() async =>
      (await _request('GET', '/System/Info/Public', auth: false)) as Map<String, dynamic>;

  /// 服务器名（Emby Web 用户菜单里用户名下面那一行，如「纸片人小站」）。
  /// 先读免登录的 /System/Info/Public；读不到（空名称、按 UA / 未登录拦截）时，已登录的 Emby / Jellyfin
  /// 再读登录后的 /System/Info。都读不到返回空字符串
  Future<String> serverName() async {
    String pick(Object? m) => m is Map ? (m['ServerName'] as String?)?.trim() ?? '' : '';
    try {
      final n = pick(await publicInfo());
      if (n.isNotEmpty) return n;
    } catch (_) {}
    if (!_server.loggedIn || (_server.type != ServerType.emby && _server.type != ServerType.jellyfin)) return '';
    try {
      return pick(await _request('GET', '/System/Info'));
    } catch (_) {
      return '';
    }
  }

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
      () => _once(
        (dio) => dio.postUri<dynamic>(
          url,
          data: {'Username': _server.username, 'Pw': password},
          options: Options(headers: headers, contentType: Headers.jsonContentType),
        ),
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
    bool staleRetried = false,
    bool idempotent = false,
    bool bytes = false,
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
          () => _once(
            (dio) => dio.requestUri<dynamic>(
              url,
              data: body,
              options: Options(
                method: method,
                headers: {...c.headers(RequestKind.api), ..._signedHeaders(method, path, query, body)},
                contentType: Headers.jsonContentType,
                responseType: bytes ? ResponseType.bytes : null,
              ),
            ),
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
          return await _request(
            method,
            path,
            query: query,
            body: body,
            auth: auth,
            retried: true,
            staleRetried: staleRetried,
            idempotent: idempotent,
            bytes: bytes,
          );
        }
        if (r.statusCode == 401) throw const MediaServerException('登录已失效，请重新登录', statusCode: 401);
        if (r.statusCode != null && r.statusCode! >= 400) {
          throw MediaServerException('服务器返回 HTTP ${r.statusCode}', statusCode: r.statusCode);
        }
        return r.data;
      } on DioException catch (e) {
        lastError = e;
        if (e.type == DioExceptionType.badResponse) {
          // 502 / 503 / 504 多半是这条线路上的反代或网关出错：换下一条线路试试；其他 5xx 是服务器本身出错，换线路也一样
          if (const {502, 503, 504}.contains(e.response?.statusCode)) continue;
          break;
        }
        // 连接池里的空闲连接可能刚好被服务器 / 反代关掉（请求发出去才发现）：GET 在同一条线路上用新连接重试一次，
        // 不然只有一条线路时会偶尔报「网络错误」
        // 播放上报重复发一次也没关系（服务器按最后一次记），同样重试
        if ((method == 'GET' || idempotent) && !staleRetried && e.error is HttpException) {
          return _request(
            method,
            path,
            query: query,
            body: body,
            auth: auth,
            retried: retried,
            staleRetried: true,
            idempotent: idempotent,
            bytes: bytes,
          );
        }
        continue; // 连接失败 / 超时：换下一条线路
      }
    }
    throw MediaServerException(
      _describe(lastError),
      statusCode: lastError is DioException ? lastError.response?.statusCode : null,
      connectionFailure:
          lastError is DioException &&
          (const {
                DioExceptionType.connectionError,
                DioExceptionType.connectionTimeout,
                DioExceptionType.receiveTimeout,
                DioExceptionType.sendTimeout,
                DioExceptionType.badCertificate,
              }.contains(lastError.type) ||
              lastError.error is SocketException ||
              lastError.error is HttpException ||
              lastError.error is HandshakeException),
    );
  }

  /// 每个请求单独算的请求头（飞牛影视的签名）；[body] 是原样发出的请求体
  Map<String, String> _signedHeaders(String method, String path, Map<String, String>? query, Object? body) => const {};

  String _describe(Object? e) {
    if (e is DioException) {
      return switch (e.type) {
        DioExceptionType.badResponse => describeServerError(e.response?.statusCode),
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
      _parentalActive ? {'MaxOfficialRating': config.parental.maxOfficialRating} : const {};

  /// 儿童模式是否作用于这次请求：[unfilteredByParental] 里（聚合索引同步）不过滤
  bool get _parentalActive => config.parental.enabled && Zone.current[_unfilteredKey] != true;

  static final _unfilteredKey = Object();

  /// 在 [body] 里发出的列表请求不按儿童模式过滤。聚合索引要存完整片库（儿童模式和普通模式共用一个索引，
  /// 读取时再按 itemVisible 过滤）；不然开着儿童模式做全量同步会把受限的片从索引里删掉
  static Future<T> unfilteredByParental<T>(Future<T> Function() body) =>
      runZoned(body, zoneValues: {_unfilteredKey: true});

  Iterable<MediaItem> _allowed(Iterable<MediaItem> items) {
    final list = items.toList();
    SeriesRatings.remember(list);
    return _parentalActive ? list.where((it) => parentalAllowsItem(config.parental, it)) : list;
  }

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
    final since = DateTime.now();
    final data = await _request(
      'GET',
      '/Users/${await _userId()}/Items/Latest',
      query: {'ParentId': ?parentId, 'Limit': '$limit', 'Fields': _userFields, ..._parentalQuery, ..._imageQuery},
    );
    final list = _allowed((data as List? ?? const []).cast<Map<String, dynamic>>().map(parseItem)).toList();
    _remember(list, since);
    return list;
  }

  Future<List<MediaItem>> resume({int limit = 20}) async {
    final since = DateTime.now();
    final data = await _request(
      'GET',
      '/Users/${await _userId()}/Items/Resume',
      query: {'Limit': '$limit', 'MediaTypes': 'Video', 'Fields': _userFields, ..._parentalQuery, ..._imageQuery},
    ) as Map<String, dynamic>;
    final list = _pageItems(data);
    if (list.isEmpty && (data['TotalRecordCount'] as num? ?? 0) > 0) {
      throw const MediaServerException('服务器继续观看响应不完整');
    }
    final items = _allowed(list.map(parseItem)).toList();
    _remember(items, since);
    return items;
  }

  // ───────────────────────── 最近取到的条目 ─────────────────────────

  /// 最近从服务器取到的条目（单条详情、继续观看、最新、集列表），按账号区分。
  /// 播放页起播要知道续播位置，以前每次都要再请求一次单条详情（经反代一次约 1~2 秒，续播时等它才能打开）；
  /// 刚取过的直接用。这台设备上报播放进度、标记已看时清掉对应条目，所以不会用到自己改之前的旧进度
  static final _recentItems = <String, (DateTime, MediaItem)>{};
  static const _recentItemLimit = 400;

  String _recentKey(String id) => '${accountScope(_server)}/$id';

  /// 什么时候清掉过（上报进度、标记已看）：在这之前发出的请求拿到的可能是旧进度，不记
  static final _forgotAt = <String, DateTime>{};

  /// [since]：这批条目的请求是什么时候发出的
  void _remember(Iterable<MediaItem> items, DateTime since) {
    final now = DateTime.now();
    for (final it in items) {
      final key = _recentKey(it.id);
      final forgot = _forgotAt[key];
      if (forgot != null && !forgot.isBefore(since)) continue;
      _recentItems.remove(key);
      _recentItems[key] = (now, it);
    }
    while (_recentItems.length > _recentItemLimit) {
      _recentItems.remove(_recentItems.keys.first);
    }
  }

  /// [maxAge] 内取到过的条目；没有返回 null
  MediaItem? recentItem(String id, {Duration maxAge = const Duration(minutes: 10)}) {
    final hit = _recentItems[_recentKey(id)];
    if (hit == null || DateTime.now().difference(hit.$1) > maxAge) return null;
    return hit.$2;
  }

  /// 进度 / 已看状态要变了：之后要用最新的就得重新取
  void forgetItem(String id) {
    final key = _recentKey(id);
    _recentItems.remove(key);
    _forgotAt.remove(key);
    _forgotAt[key] = DateTime.now();
    while (_forgotAt.length > _recentItemLimit) {
      _forgotAt.remove(_forgotAt.keys.first);
    }
  }

  @visibleForTesting
  static void clearRecentItems() {
    _recentItems.clear();
    _forgotAt.clear();
  }

  Future<MediaItem> item(String id) async {
    final since = DateTime.now();
    final it = await _item(id);
    _remember([it], since);
    return it;
  }

  Future<MediaItem> _item(String id) async {
    try {
      return parseItem(
        await _request('GET', '/Users/${await _userId()}/Items/$id', query: {'Fields': _userFields})
            as Map<String, dynamic>,
      );
    } on MediaServerException catch (e) {
      if (e.statusCode != null && e.statusCode! < 500) rethrow;
      // 有些条目单独取详情时服务器报 5xx 或迟迟不回（单条接口会顺带统计预告片、花絮等，要去扫媒体文件夹，
      // 网盘挂载上可能很慢，反代等不及就报 502），但列表接口能正常返回同一条（首页卡片就是这么来的）：
      // 改用列表接口按 ID 取，界面要的字段一样
      final Object? data;
      try {
        data = await _request('GET', '/Users/${await _userId()}/Items', query: {'Ids': id, 'Fields': _userFields});
      } on MediaServerException {
        throw e;
      }
      final items = (data is Map ? data['Items'] as List? : null) ?? const [];
      if (items.isEmpty) rethrow;
      return parseItem(items.first as Map<String, dynamic>);
    }
  }

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

  /// 进度条缩略图：Jellyfin 10.9+ 的 trickplay 拼图，或 Emby 的 BIF。服务器没生成时返回 null
  Future<Trickplay?> trickplay(String itemId, String mediaSourceId) async {
    if (_server.type == ServerType.jellyfin) {
      final j = await _request(
        'GET',
        '/Users/${await _userId()}/Items/$itemId',
        query: {'Fields': 'Trickplay'},
      ) as Map<String, dynamic>;
      final tiles = TrickplayTiles.parse(j['Trickplay'], mediaSourceId);
      if (tiles == null) return null;
      return JellyfinTrickplay(
        tiles,
        (tile) async => Uint8List.fromList(
          await _request(
            'GET',
            '/Videos/$itemId/Trickplay/${tiles.width}/$tile.jpg',
            query: {'MediaSourceId': mediaSourceId},
            bytes: true,
          ) as List<int>,
        ),
      );
    }
    try {
      final data = await _request(
        'GET',
        '/Videos/$itemId/index.bif',
        query: {'Width': '320', 'MediaSourceId': mediaSourceId},
        bytes: true,
      );
      if (data is! List<int>) return null;
      return await BifTrickplay.load(data is Uint8List ? data : Uint8List.fromList(data));
    } on MediaServerException catch (e) {
      if (e.statusCode == 404) return null; // 没生成缩略图
      rethrow;
    }
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
    final since = DateTime.now();
    final data = await _request(
      'GET',
      '/Shows/$seriesId/Episodes',
      query: {'UserId': await _userId(), 'SeasonId': ?seasonId, 'Fields': _userFields, ..._imageQuery},
    ) as Map<String, dynamic>;
    final list = (data['Items'] as List? ?? const []).cast<Map<String, dynamic>>().map(parseItem).toList();
    _remember(list, since);
    return list;
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
    var original = delivery.startsWith('http') ? Uri.parse(delivery) : _onApiBase(base, delivery);
    // 请求头里不带令牌（见 RequestComposer.headers），地址里没有 api_key 时补上（服务器没给投递地址时自拼的路径就没有）
    final token = _server.token;
    // 只给媒体服务器自己的地址补：投递地址是别的主机（外部字幕源）时不能把令牌带过去
    final own = original.host.toLowerCase() == base.host.toLowerCase() && original.port == base.port;
    if (token != null && own && !original.queryParameters.keys.any((k) => k.toLowerCase() == 'api_key')) {
      original = original.replace(queryParameters: {...original.queryParameters, 'api_key': token});
    }
    final headers = c.headers(RequestKind.stream);
    return PlaybackRequest(
      url: c.finalUrl(original, RequestKind.stream),
      headers: headers,
      userAgent: headers['User-Agent']!,
    );
  }

  /// 服务器给的相对地址接到 API 根地址上；已经带了根地址的路径前缀（如 `/emby/Videos/…`）时不再重复拼
  static Uri _onApiBase(Uri base, String relative) {
    final i = relative.indexOf('?');
    var path = i < 0 ? relative : relative.substring(0, i);
    final query = i < 0 ? null : relative.substring(i + 1);
    if (!path.startsWith('/')) path = '/$path';
    final prefix = base.path;
    final hasPrefix =
        prefix.isNotEmpty &&
        (path.toLowerCase() == prefix.toLowerCase() || path.toLowerCase().startsWith('${prefix.toLowerCase()}/'));
    return base.replace(path: hasPrefix ? path : '$prefix$path', query: query == null || query.isEmpty ? null : query);
  }

  /// 交给播放器加载的外挂字幕地址（播放器加载外挂字幕时带不上请求头，需要签名的服务器先下载到本机）
  Future<Uri?> subtitleUri(MediaSourceInfo source, MediaStreamInfo stream) async => subtitle(source, stream)?.url;

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

  /// 返回服务器有没有收到（没收到的停止上报由 PendingPlayReports 存下来，下次启动补发）
  Future<bool> reportStopped(MediaSourceInfo s, Duration position, String? playSessionId) =>
      _report('/Sessions/Playing/Stopped', s, position, playSessionId);

  /// 还没发完的播放上报（应用内更新重启前先等它们发完，不然这次播放的进度可能没报上去）
  static final _pendingReports = <Future<bool>>{};

  /// 等还没发完的播放上报，最多等 [timeout]
  static Future<void> flushReports({Duration timeout = const Duration(seconds: 5)}) async {
    if (_pendingReports.isEmpty) return;
    try {
      await Future.wait(_pendingReports.toList()).timeout(timeout);
    } catch (_) {}
  }

  Future<bool> _report(
    String path,
    MediaSourceInfo s,
    Duration position,
    String? playSessionId, {
    bool paused = false,
    String? event,
  }) {
    // 上报前后都清：上报还没被服务器处理时发出的列表请求（比如退出播放后首页立刻刷新「继续观看」）
    // 拿到的是旧进度，不能记下来给下次起播用
    forgetItem(s.itemId);
    final f = _sendReport(path, s, position, playSessionId, paused: paused, event: event);
    _pendingReports.add(f);
    return f.whenComplete(() {
      _pendingReports.remove(f);
      forgetItem(s.itemId);
    });
  }

  Future<bool> _sendReport(
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
        idempotent: true,
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
      // 开始 / 停止写进日志（进度上报每 10 秒一次，只记失败）：服务器上进度不对时能看出有没有报上去
      if (!path.endsWith('/Progress')) debugPrint('report $path ok ${s.itemId} @${position.inSeconds}s');
      return true;
    } catch (e) {
      debugPrint('report $path failed: $e');
      return false;
    }
  }

  Future<void> setPlayed(String itemId, bool played) async {
    forgetItem(itemId);
    await _request(played ? 'POST' : 'DELETE', '/Users/${await _userId()}/PlayedItems/$itemId');
    forgetItem(itemId);
  }

  Future<void> setFavorite(String itemId, bool favorite) async =>
      _request(favorite ? 'POST' : 'DELETE', '/Users/${await _userId()}/FavoriteItems/$itemId');

  // ───────────────────────── 图片 ─────────────────────────

  /// 一张服务器图片加载失败时调用（[ServerImage]）。Emby / Jellyfin 的图不用登录，什么都不做；
  /// 飞牛会借此检查令牌是否过期，过期就重新登录
  Future<void> onImageFailed() async {}

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
