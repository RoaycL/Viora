import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';

/// 在线字幕的语言：中文（简繁）/ 英文
enum SubtitleLanguage {
  chinese('中文', 'chi'),
  english('英文', 'eng');

  const SubtitleLanguage(this.label, this.code);
  final String label;

  /// 三字母代码（媒体服务器的字幕搜索用）
  final String code;
}

/// 要找字幕的片子：剧集用剧的 TMDB / IMDb ID 加季、集
class SubtitleQuery {
  const SubtitleQuery({
    required this.title,
    this.originalTitle,
    this.year,
    this.tmdbId,
    this.imdbId,
    this.season,
    this.episode,
  });

  /// 电影名或剧名（中文）
  final String title;

  /// 原名（多为英文）：射手网（伪）按英文名搜得更准
  final String? originalTitle;
  final int? year;
  final int? tmdbId;
  final String? imdbId;
  final int? season;
  final int? episode;

  bool get isEpisode => season != null && episode != null;

  /// 「Name S01E02」
  String keyword(String name) =>
      isEpisode ? '$name S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}' : name;
}

/// 一条在线字幕（搜索结果）
class OnlineSubtitle {
  const OnlineSubtitle({
    required this.provider,
    required this.id,
    required this.name,
    this.language,
    this.format,
    this.downloads,
    this.searchLanguage,
    this.season,
    this.episode,
  });

  /// [OpenSubtitlesClient.providerName] / [AssrtClient.providerName]
  final String provider;
  final String id;
  final String name;

  /// 显示用的语言说明，如「简体」「简 英」「en」
  final String? language;
  final String? format;
  final int? downloads;

  /// 搜索时要的语言：字幕包里有多种语言的文件时，按它挑
  final SubtitleLanguage? searchLanguage;

  /// 搜索的是第几季第几集：整季打包的字幕里按它挑对应那一集的文件
  final int? season;
  final int? episode;
}

/// 下载下来的字幕文件
class SubtitleFile {
  const SubtitleFile(this.fileName, this.bytes);
  final String fileName;
  final List<int> bytes;
}

class OnlineSubtitleException implements Exception {
  const OnlineSubtitleException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class OnlineSubtitleProvider {
  String get name;
  Future<List<OnlineSubtitle>> search(SubtitleQuery query, SubtitleLanguage language);
  Future<SubtitleFile> download(OnlineSubtitle subtitle);
}

Dio _newDio() => Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.json,
  ),
);

String _dioMessage(DioException e) =>
    e.response?.statusCode != null ? 'HTTP ${e.response!.statusCode}' : (e.message ?? e.type.name);

String _ext(String fileName) {
  final i = fileName.lastIndexOf('.');
  return i < 0 ? '' : fileName.substring(i + 1).toLowerCase();
}

const _textFormats = {'srt', 'ass', 'ssa', 'vtt'};

// ───────────────────────── OpenSubtitles ─────────────────────────

/// OpenSubtitles REST API（api.opensubtitles.com）：内置应用 Key，用户可选登录自己的账号提高下载次数
class OpenSubtitlesClient implements OnlineSubtitleProvider {
  OpenSubtitlesClient(this.config, {Dio? dio, this.apiKey = SubtitleSourcesConfig.builtinOpenSubtitlesKey, String? baseUrl})
    : _dio = dio ?? _newDio(),
      _baseUrl = baseUrl ?? 'https://api.opensubtitles.com/api/v1';

  static const providerName = 'OpenSubtitles';

  final SubtitleSourcesConfig config;
  final String apiKey;
  final Dio _dio;
  String _baseUrl;

  /// 登录令牌（同一账号进程内复用，24 小时内有效）
  static final _tokens = <String, (String token, String? baseUrl, DateTime expires)>{};

  /// 官方令牌 24 小时有效：提前一小时换新的
  static const tokenLifetime = Duration(hours: 23);

  @override
  String get name => providerName;

  Map<String, String> get _headers => {
    'Api-Key': apiKey,
    // OpenSubtitles 要求 User-Agent 带应用名和版本
    'User-Agent': 'Viora v$subtitleClientVersion',
    'Accept': 'application/json',
  };

  static String _languages(SubtitleLanguage l) => switch (l) {
    SubtitleLanguage.chinese => 'zh-cn,zh-tw',
    SubtitleLanguage.english => 'en',
  };

  /// 搜索参数（按字母顺序：官方建议排好序，命中缓存更快）
  static Map<String, String> searchParams(SubtitleQuery q, SubtitleLanguage l) {
    final imdb = q.imdbId?.replaceFirst(RegExp('^tt'), '');
    final p = <String, String>{'languages': _languages(l)};
    if (q.isEpisode) {
      p['season_number'] = '${q.season}';
      p['episode_number'] = '${q.episode}';
      if (q.tmdbId != null) {
        p['parent_tmdb_id'] = '${q.tmdbId}';
      } else if (imdb != null && imdb.isNotEmpty) {
        p['parent_imdb_id'] = imdb;
      } else {
        p['query'] = (q.originalTitle ?? q.title).toLowerCase();
      }
    } else if (q.tmdbId != null) {
      p['tmdb_id'] = '${q.tmdbId}';
    } else if (imdb != null && imdb.isNotEmpty) {
      p['imdb_id'] = imdb;
    } else {
      p['query'] = (q.originalTitle ?? q.title).toLowerCase();
      if (q.year != null) p['year'] = '${q.year}';
    }
    return Map.fromEntries(p.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  }

  @override
  Future<List<OnlineSubtitle>> search(SubtitleQuery query, SubtitleLanguage language) async {
    if (apiKey.isEmpty) return const [];
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '$_baseUrl/subtitles',
        queryParameters: searchParams(query, language),
        options: Options(headers: _headers),
      );
      return [
        for (final d in (r.data?['data'] as List? ?? const []).whereType<Map<String, dynamic>>())
          ?_parse(d),
      ]..sort((a, b) => (b.downloads ?? 0).compareTo(a.downloads ?? 0));
    } on DioException catch (e) {
      throw OnlineSubtitleException('OpenSubtitles 搜索失败：${_dioMessage(e)}');
    }
  }

  static OnlineSubtitle? _parse(Map<String, dynamic> d) {
    final a = d['attributes'];
    if (a is! Map<String, dynamic>) return null;
    final file = (a['files'] as List? ?? const []).whereType<Map<String, dynamic>>().firstOrNull;
    final fileId = file?['file_id'];
    if (fileId == null) return null;
    final fileName = file?['file_name']?.toString() ?? '';
    final release = a['release']?.toString() ?? '';
    return OnlineSubtitle(
      provider: providerName,
      id: '$fileId',
      name: release.isNotEmpty ? release : fileName,
      language: a['language']?.toString(),
      format: _ext(fileName).isEmpty ? 'srt' : _ext(fileName),
      downloads: (a['download_count'] as num?)?.toInt(),
    );
  }

  Future<String?> _login() async {
    if (!config.osLoggedIn) return null;
    final key = '${config.osUsername.trim()}\u0000${config.osPassword}';
    final cached = _tokens[key];
    if (cached != null && DateTime.now().isAfter(cached.$3)) _tokens.remove(key);
    if (cached != null && _tokens.containsKey(key)) {
      if (cached.$2 != null) _baseUrl = cached.$2!;
      return cached.$1;
    }
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '$_baseUrl/login',
        data: {'username': config.osUsername.trim(), 'password': config.osPassword},
        options: Options(headers: {..._headers, 'Content-Type': 'application/json'}),
      );
      final token = r.data?['token']?.toString();
      if (token == null || token.isEmpty) throw const OnlineSubtitleException('OpenSubtitles 登录失败');
      // VIP 账号会给专用的 API 地址
      final host = r.data?['base_url']?.toString();
      final base = host == null || host.isEmpty ? null : 'https://$host/api/v1';
      _tokens[key] = (token, base, DateTime.now().add(tokenLifetime));
      if (base != null) _baseUrl = base;
      return token;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      throw OnlineSubtitleException(
        code == 401 ? 'OpenSubtitles 账号或密码不对（设置 → 接口与网络 → 在线字幕）' : 'OpenSubtitles 登录失败：${_dioMessage(e)}',
      );
    }
  }

  /// 测试登录（设置页「保存并测试」）
  Future<void> testLogin() async {
    _tokens.clear();
    await _login();
  }

  @override
  Future<SubtitleFile> download(OnlineSubtitle subtitle) async {
    Future<Map<String, dynamic>?> request() async {
      final token = await _login();
      final auth = token == null ? null : 'Bearer $token';
      final r = await _dio.post<Map<String, dynamic>>(
        '$_baseUrl/download',
        data: {'file_id': int.tryParse(subtitle.id) ?? subtitle.id},
        options: Options(
          headers: {..._headers, 'Content-Type': 'application/json', 'Authorization': ?auth},
        ),
      );
      return r.data;
    }

    Map<String, dynamic>? info;
    try {
      try {
        info = await request();
      } on DioException catch (e) {
        // 令牌被服务器作废（过期、在别处改了密码）：重新登录再试一次
        if (e.response?.statusCode != 401 || !config.osLoggedIn) rethrow;
        _tokens.clear();
        info = await request();
      }
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 406 || code == 429) {
        throw OnlineSubtitleException(
          config.osLoggedIn
              ? 'OpenSubtitles 今天的下载次数已用完，明天再试'
              : 'OpenSubtitles 今天的匿名下载次数已用完：可以在设置 → 接口与网络 → 在线字幕里登录自己的账号',
        );
      }
      throw OnlineSubtitleException('OpenSubtitles 下载失败：${_dioMessage(e)}');
    }
    final link = info?['link']?.toString();
    if (link == null || link.isEmpty) {
      throw OnlineSubtitleException(info?['message']?.toString() ?? 'OpenSubtitles 没有返回下载地址');
    }
    final fileName = info?['file_name']?.toString() ?? '${subtitle.id}.srt';
    try {
      final r = await _dio.get<List<int>>(link, options: Options(responseType: ResponseType.bytes));
      return SubtitleFile(fileName, r.data ?? const []);
    } on DioException catch (e) {
      throw OnlineSubtitleException('OpenSubtitles 下载失败：${_dioMessage(e)}');
    }
  }
}

/// 请求头里的客户端版本（启动时设置成应用版本）
String subtitleClientVersion = '1.0';

// ───────────────────────── 射手网（伪） ─────────────────────────

/// 射手网（伪）API（api.assrt.net）：中文字幕最全；需要用户自己的 token
class AssrtClient implements OnlineSubtitleProvider {
  AssrtClient(this.token, {Dio? dio, String? baseUrl})
    : _dio = dio ?? _newDio(),
      _baseUrl = baseUrl ?? 'https://api.assrt.net/v1';

  static const providerName = '射手网（伪）';

  final String token;
  final Dio _dio;
  final String _baseUrl;

  @override
  String get name => providerName;

  Future<Map<String, dynamic>> _get(String path, Map<String, String> query) async {
    Object? body;
    try {
      final r = await _dio.get<Object>(
        '$_baseUrl$path',
        queryParameters: {'token': token, ...query},
        options: Options(headers: {'User-Agent': 'Viora v$subtitleClientVersion'}),
      );
      body = r.data;
    } on DioException catch (e) {
      // 出错时（4xx / 5xx）响应里同样带 status，按它说明原因
      body = e.response?.data;
      if (body == null) throw OnlineSubtitleException('射手网（伪）请求失败：${_dioMessage(e)}');
    }
    Object? j = body;
    if (body is String) {
      try {
        j = jsonDecode(body);
      } on FormatException {
        j = null;
      }
    }
    if (j is! Map<String, dynamic>) throw const OnlineSubtitleException('射手网（伪）返回格式不对');
    final status = (j['status'] as num?)?.toInt() ?? 0;
    if (status != 0) {
      throw OnlineSubtitleException(switch (status) {
        1 || 20001 => '射手网（伪）的 token 不对（设置 → 接口与网络 → 在线字幕）',
        101 => '射手网（伪）：搜索关键词太短',
        20900 => '射手网（伪）：这条字幕已经不存在',
        30900 => '射手网（伪）请求太频繁（每分钟 20 次），请稍后再试',
        _ => '射手网（伪）：${j['errmsg'] ?? '错误 $status'}',
      });
    }
    return j;
  }

  /// 测试 token（设置页「保存并测试」）：返回每分钟的请求额度
  Future<int?> quota() async {
    final j = await _get('/user/quota', const {});
    return ((j['user'] as Map?)?['quota'] as num?)?.toInt();
  }

  static bool _matches(Map<String, dynamic> lang, SubtitleLanguage l) {
    final list = lang['langlist'];
    if (list is! Map) return true;
    bool has(String k) => list[k] == true;
    return switch (l) {
      SubtitleLanguage.chinese => has('langchs') || has('langcht') || has('langdou'),
      SubtitleLanguage.english => has('langeng') || has('langdou'),
    };
  }

  @override
  Future<List<OnlineSubtitle>> search(SubtitleQuery query, SubtitleLanguage language) async {
    if (token.trim().isEmpty) return const [];
    // 先按原名（英文）搜，搜不到再按中文名
    final names = {
      if (query.originalTitle?.trim().isNotEmpty ?? false) query.originalTitle!.trim(),
      query.title.trim(),
    };
    for (final name in names) {
      final keyword = query.keyword(name);
      // 关键词至少要比 3 个字长（如电影《Up》），太短的跳过，改用下一个名字
      if (keyword.runes.length <= 3) continue;
      final j = await _get('/sub/search', {'q': keyword, 'cnt': '30', 'pos': '0'});
      final subs = ((j['sub'] as Map?)?['subs'] as List? ?? const []).whereType<Map<String, dynamic>>();
      final list = [
        for (final s in subs)
          if (_matches(s['lang'] as Map<String, dynamic>? ?? const {}, language))
            OnlineSubtitle(
              provider: providerName,
              id: '${s['id']}',
              name: (s['native_name']?.toString().trim().isNotEmpty ?? false)
                  ? '${s['native_name']}'
                  : '${s['videoname'] ?? s['id']}',
              language: (s['lang'] as Map?)?['desc']?.toString(),
              format: s['subtype']?.toString(),
              searchLanguage: language,
              season: query.season,
              episode: query.episode,
            ),
      ];
      if (list.isNotEmpty) return list;
    }
    return const [];
  }

  /// 字幕包里挑一个文件：要求是文本字幕；中文优先挑简体，其次繁体；英文优先挑英文文件，避开纯中文的
  static Map<String, dynamic>? pickFile(
    List<Map<String, dynamic>> files, [
    SubtitleLanguage? language,
    int? season,
    int? episode,
  ]) {
    var text = [
      for (final f in files)
        if (_textFormats.contains(_ext('${f['f'] ?? ''}'))) f,
    ];
    if (text.isEmpty) return null;
    // 整季打包：只在对应那一集的文件里挑（文件名里认不出集数时不过滤）
    if (episode != null) {
      final sameEpisode = [
        for (final f in text)
          if (episodeOf('${f['f']}') case (final s, final e) when e == episode && (s == null || season == null || s == season)) f,
      ];
      if (sameEpisode.isNotEmpty) {
        text = sameEpisode;
      } else if (text.any((f) => episodeOf('${f['f']}') != null)) {
        return null;
      }
    }
    int score(Map<String, dynamic> f) {
      final n = '${f['f']}'.toLowerCase();
      var s = 0;
      final chs = RegExp(r'chs|简|sc\b|\.zh|gb').hasMatch(n);
      final cht = RegExp(r'cht|繁|tc\b|big5').hasMatch(n);
      final eng = RegExp(r'\beng?\b|english|英').hasMatch(n);
      if (language == SubtitleLanguage.english) {
        if (eng) s += 4;
        if (chs || cht) s -= eng ? 1 : 4;
      } else {
        if (chs) s += 4;
        if (cht) s += 2;
      }
      if (_ext(n) == 'ass' || _ext(n) == 'ssa') s += 1;
      return s;
    }

    return (text..sort((a, b) => score(b).compareTo(score(a)))).first;
  }

  /// 文件名里的季和集：S01E02 / 1x02 / EP02 / 第02集
  static (int?, int)? episodeOf(String fileName) {
    final n = fileName.toLowerCase();
    final se = RegExp(r's(\d{1,2})[ ._-]?e(\d{1,3})').firstMatch(n) ?? RegExp(r'\b(\d{1,2})x(\d{2,3})\b').firstMatch(n);
    if (se != null) return (int.parse(se[1]!), int.parse(se[2]!));
    final e = RegExp(r'(?:\bep?|第)(\d{1,3})(?:\b|集|话)').firstMatch(n);
    if (e != null) return (null, int.parse(e[1]!));
    return null;
  }

  @override
  Future<SubtitleFile> download(OnlineSubtitle subtitle) async {
    final j = await _get('/sub/detail', {'id': subtitle.id});
    final sub = ((j['sub'] as Map?)?['subs'] as List? ?? const []).whereType<Map<String, dynamic>>().firstOrNull;
    if (sub == null) throw const OnlineSubtitleException('射手网（伪）没有这条字幕的详情');
    final files = (sub['filelist'] as List? ?? const []).whereType<Map<String, dynamic>>().toList();
    var file = pickFile(files, subtitle.searchLanguage, subtitle.season, subtitle.episode);
    // 单个文件（没有打包）时 filelist 为空，直接用 url
    if (file == null && files.isEmpty && _textFormats.contains(_ext('${sub['filename'] ?? ''}'))) {
      file = {'url': sub['url'], 'f': sub['filename']};
    }
    final url = file?['url']?.toString();
    if (file == null || url == null || url.isEmpty) {
      if (subtitle.episode != null && pickFile(files, subtitle.searchLanguage) != null) {
        throw OnlineSubtitleException('这个字幕包里没有第 ${subtitle.episode} 集，换一条试试');
      }
      throw const OnlineSubtitleException('这条字幕只有压缩包，没有可直接加载的字幕文件，换一条试试');
    }
    try {
      final r = await _dio.get<List<int>>(url, options: Options(responseType: ResponseType.bytes));
      return SubtitleFile('${file['f']}', r.data ?? const []);
    } on DioException catch (e) {
      throw OnlineSubtitleException('射手网（伪）下载失败：${_dioMessage(e)}');
    }
  }
}

// ───────────────────────── 保存到本地 ─────────────────────────

/// 字幕文本统一转成 UTF-8（ExoPlayer 只认 UTF-8 / 带 BOM 的 UTF-16；GBK 等其他编码原样保留，mpv 会自动识别）
List<int> normalizeSubtitleBytes(List<int> bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) return bytes.sublist(3);
  if (bytes.length >= 2 && (bytes[0] == 0xFF && bytes[1] == 0xFE || bytes[0] == 0xFE && bytes[1] == 0xFF)) {
    final le = bytes[0] == 0xFF;
    final units = <int>[
      for (var i = 2; i + 1 < bytes.length; i += 2) le ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1],
    ];
    return utf8.encode(String.fromCharCodes(units));
  }
  return bytes;
}

/// 存到临时目录，返回本地路径（文件名保留扩展名：播放器按扩展名识别格式）
Future<String> saveSubtitleFile(SubtitleFile file, {Directory? dir}) async {
  final base = dir ?? Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}viora_subtitles');
  await base.create(recursive: true);
  var name = file.fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  if (!_textFormats.contains(_ext(name))) name = '$name.srt';
  // 文件系统限制的是字节数（一般 255 字节），中文一个字 3 字节：按 UTF-8 字节截掉开头，留出时间戳前缀的位置
  final runes = name.runes.toList();
  var start = 0;
  while (utf8.encode(String.fromCharCodes(runes.sublist(start))).length > 180) {
    start++;
  }
  name = String.fromCharCodes(runes.sublist(start));
  final out = File('${base.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}_$name');
  await out.writeAsBytes(normalizeSubtitleBytes(file.bytes), flush: true);
  return out.path;
}

/// 已启用的在线字幕来源（OpenSubtitles 有内置 Key 时启用；射手网（伪）填了 token 时启用）
List<OnlineSubtitleProvider> onlineSubtitleProviders(SubtitleSourcesConfig config) => [
  if (config.assrtEnabled) AssrtClient(config.assrtToken.trim()),
  if (config.openSubtitlesEnabled) OpenSubtitlesClient(config),
];
