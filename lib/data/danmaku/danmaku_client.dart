import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
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

/// 弹弹play 开放平台的签名头：X-Signature = base64(sha256(AppId + Timestamp + Path + AppSecret))，Path 不含查询参数
Map<String, String> dandanplaySignature(String appId, String secret, String path, int timestamp) => {
  'X-AppId': appId,
  'X-Timestamp': '$timestamp',
  'X-Signature': base64.encode(sha256.convert(utf8.encode('$appId$timestamp$path$secret')).bytes),
};

/// 弹幕客户端：自己的 danmu_api（弹弹play 兼容接口）+ 内置弹弹play，多个服务器并发搜索，
/// 结果按 animeId 去重并记住来自哪个服务器
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
          ) {
    // 发往内置弹弹play 的请求加签名（每个请求单独算，时间戳要新）
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (isBuiltin(options.uri.toString())) {
            options.headers.addAll(
              dandanplaySignature(
                DanmakuConfig.builtinAppId,
                DanmakuConfig.builtinAppSecret,
                options.uri.path,
                DateTime.now().millisecondsSinceEpoch ~/ 1000,
              ),
            );
          }
          handler.next(options);
        },
      ),
    );
  }

  final DanmakuConfig config;
  final Dio _dio;

  List<String> get servers => config.allServers;

  /// 这个地址 / 服务器是不是内置的弹弹play
  static bool isBuiltin(String url) =>
      DanmakuConfig.builtinAvailable && (url == DanmakuConfig.builtinServer || url.startsWith('${DanmakuConfig.builtinServer}/'));

  /// 搜索结果、弹幕来源里显示的服务器名（只标内置的弹弹play，自己的服务器不标）
  static String? sourceLabel(String server) => isBuiltin(server) ? '弹弹play' : null;

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
    final seen = <String>{};
    // 自己的服务器在前；内置弹弹play 和它们编号不同，按标题去掉同一部作品的重复条目
    final titles = <String>{
      for (var i = 0; i < results.length; i++)
        if (!isBuiltin(servers[i]))
          for (final a in results[i]) sameTitleKey(a.title),
    };
    final merged = [
      for (var i = 0; i < results.length; i++)
        for (final a in results[i])
          if (seen.add('${isBuiltin(servers[i]) ? 'b' : 'u'}#${a.animeId}') &&
              (!isBuiltin(servers[i]) || !titles.contains(sameTitleKey(a.title))))
            a,
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
              // 弹弹play 默认要文件哈希；我们只有文件名
              data: {'fileName': fileName, if (isBuiltin(server)) 'matchMode': 'fileNameOnly'},
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

/// 判断两个来源的作品是不是同一部：去掉空格、【来源】标记、（年份）后比较
String sameTitleKey(String title) => title
    .toLowerCase()
    .replaceAll(RegExp(r'【[^】]*】|\[[^\]]*\]'), '')
    .replaceAll(RegExp(r'[（(]\d{4}[)）]'), '')
    .replaceAll(RegExp(r'\s+'), '');
