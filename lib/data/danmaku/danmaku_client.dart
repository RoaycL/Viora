import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import 'danmaku_models.dart';

/// 自动匹配（`POST /api/v2/match`）的结果
class DanmakuMatch {
  const DanmakuMatch({
    required this.server,
    required this.episodeId,
    required this.animeId,
    required this.animeTitle,
    required this.episodeTitle,
  });

  final String server;
  final int episodeId;
  final int animeId;
  final String animeTitle;
  final String episodeTitle;
}

/// danmu_api（弹弹play 兼容接口）客户端：多个服务器并发搜索，结果按 animeId 去重并记住来自哪个服务器
class DanmakuClient {
  DanmakuClient(this.config, {Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              // 第一次取某一集时服务器要去各视频站抓取，可能比较慢
              receiveTimeout: const Duration(seconds: 60),
              headers: {'Accept': 'application/json', 'User-Agent': 'Viora'},
              responseType: ResponseType.plain,
            ),
          );

  final DanmakuConfig config;
  final Dio _dio;

  List<String> get servers => config.activeServers;

  /// 解析后的原始弹幕（过滤前），最近 4 集；换下一集 / 切换资源时不用重新下载
  static final _commentCache = <String, List<DanmakuComment>>{};

  Future<Map<String, dynamic>> _get(String url, {Map<String, dynamic>? query}) async {
    final r = await _dio.get<String>(url, queryParameters: query);
    return _decode(r.data);
  }

  static Map<String, dynamic> _decode(String? body) {
    final j = jsonDecode(body ?? '{}');
    if (j is! Map<String, dynamic>) throw const FormatException('弹幕服务器返回格式不对');
    if (j['success'] == false) throw DanmakuException(j['errorMessage']?.toString() ?? '弹幕服务器返回错误');
    return j;
  }

  /// 测试服务器：空关键词搜索很快返回；token 不对时返回 401
  static Future<void> test(String server, {Dio? dio}) async {
    final client = DanmakuClient(const DanmakuConfig(), dio: dio);
    try {
      await client._get('$server/api/v2/search/anime', query: {'keyword': ''});
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) throw const DanmakuException('token 不对（地址格式：https://域名/token）');
      if (code == 404) throw const DanmakuException('地址不对，找不到弹幕接口（地址格式：https://域名/token）');
      throw DanmakuException(code != null ? 'HTTP $code' : (e.message ?? '连接失败'));
    }
  }

  /// 在所有服务器上搜索作品（并发）；要找的那一季排前面
  Future<List<DanmakuAnime>> search(String keyword, {int? season, bool movie = false}) async {
    final results = await Future.wait([
      for (final server in servers)
        _get('$server/api/v2/search/anime', query: {'keyword': keyword}).then(
          (j) => [
            for (final a in (j['animes'] as List? ?? const []))
              if (a is Map<String, dynamic>) DanmakuAnime.fromJson(server, a),
          ],
          onError: (_) => <DanmakuAnime>[],
        ),
    ]);
    final seen = <int>{};
    final merged = [
      for (final list in results)
        for (final a in list)
          if (seen.add(a.animeId)) a,
    ];
    return rankAnimes(
      merged,
      keyword,
      season: season,
      movie: movie,
      blockWords: splitKeywords(config.searchBlockWords),
    );
  }

  Future<List<DanmakuEpisode>> episodes(DanmakuAnime anime) async {
    final j = await _get('${anime.server}/api/v2/bangumi/${anime.animeId}');
    final eps = (j['bangumi'] as Map?)?['episodes'] as List? ?? const [];
    return [
      for (final e in eps)
        if (e is Map<String, dynamic>) DanmakuEpisode.fromJson(anime.server, e),
    ];
  }

  /// 按「标题 S01E02」自动匹配；按服务器顺序取第一个匹配上的
  Future<DanmakuMatch?> match(String fileName) async {
    final results = await Future.wait([
      for (final server in servers)
        _dio
            .post<String>(
              '$server/api/v2/match',
              data: {'fileName': fileName},
              options: Options(contentType: Headers.jsonContentType),
            )
            .then<DanmakuMatch?>((r) {
              final j = _decode(r.data);
              final m = (j['matches'] as List? ?? const []).whereType<Map<String, dynamic>>().firstOrNull;
              if (j['isMatched'] != true || m == null) return null;
              final id = (m['episodeId'] as num?)?.toInt();
              if (id == null) return null;
              return DanmakuMatch(
                server: server,
                episodeId: id,
                animeId: (m['animeId'] as num?)?.toInt() ?? 0,
                animeTitle: m['animeTitle']?.toString() ?? '',
                episodeTitle: m['episodeTitle']?.toString() ?? '',
              );
            }, onError: (_) => null),
    ]);
    return results.whereType<DanmakuMatch>().firstOrNull;
  }

  /// 取一集弹幕并按设置过滤（繁简、屏蔽词、数量上限、颜色）
  Future<DanmakuTrack> load(String server, int episodeId, {required String source}) async {
    final key = '$server#$episodeId';
    var raw = _commentCache[key];
    if (raw == null) {
      final r = await _dio.get<String>(
        '$server/api/v2/comment/$episodeId',
        queryParameters: {'withRelated': 'true', 'chConvert': '0', 'format': 'json'},
      );
      // 一集热门剧的弹幕有一两万条、几 MB：JSON 解析放到后台线程，不卡界面（低配电视起播后几秒遥控器没反应）
      final parsed = await compute(_parseBody, r.data);
      raw = parsed;
      // 服务器偶尔抓取源站失败返回 0 条：不缓存，下次重新取
      if (parsed.isNotEmpty) {
        _commentCache.remove(key);
        _commentCache[key] = parsed;
        while (_commentCache.length > 4) {
          _commentCache.remove(_commentCache.keys.first);
        }
      }
    }
    // 繁简转换、屏蔽词、数量上限同样在后台线程做
    final comments = await compute(_process, (
      raw,
      config.convert,
      splitKeywords(config.blockWords),
      config.maxCount,
      config.colorMode,
    ));
    return DanmakuTrack(comments: comments, source: source, server: server, episodeId: episodeId);
  }
}

List<DanmakuComment> _parseBody(String? body) => parseComments(DanmakuClient._decode(body));

List<DanmakuComment> _process((List<DanmakuComment>, DanmakuConvert, List<String>, int, DanmakuColorMode) a) =>
    processComments(a.$1, convert: a.$2, blockWords: a.$3, maxCount: a.$4, colorMode: a.$5);

class DanmakuException implements Exception {
  const DanmakuException(this.message);
  final String message;

  @override
  String toString() => message;
}
