import 'dart:math';

import '../danmaku/danmaku_models.dart';

/// 本地保存的全部配置（服务器、线路、反向代理、播放 UA 等），整体序列化为一个 JSON。
/// 设计见 docs/02-architecture.md §2、docs/03-media-servers.md。

enum ServerType {
  emby('Emby'),
  jellyfin('Jellyfin');

  const ServerType(this.label);
  final String label;

  static ServerType parse(String? s) => values.firstWhere((t) => t.name == s, orElse: () => emby);
}

class ServerLine {
  const ServerLine({required this.id, required this.name, required this.url, this.proxied = false, this.latencyMs});

  final String id;
  final String name;

  /// 服务器地址，如 `https://emby.example.com:8920`（可带 `/emby` 路径）
  final String url;

  /// 是否走反向代理
  final bool proxied;

  /// 最近一次测速结果；null = 未测 / 不可用
  final int? latencyMs;

  ServerLine copyWith({String? name, String? url, bool? proxied, int? latencyMs, bool clearLatency = false}) =>
      ServerLine(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        proxied: proxied ?? this.proxied,
        latencyMs: clearLatency ? null : (latencyMs ?? this.latencyMs),
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url, 'proxied': proxied, 'latencyMs': latencyMs};

  factory ServerLine.fromJson(Map<String, dynamic> j) => ServerLine(
    id: j['id'] as String,
    name: j['name'] as String? ?? '线路',
    url: j['url'] as String,
    proxied: j['proxied'] as bool? ?? false,
    latencyMs: j['latencyMs'] as int?,
  );
}

class ServerConfig {
  const ServerConfig({
    required this.id,
    required this.type,
    required this.name,
    required this.lines,
    required this.username,
    this.password = '',
    this.userId,
    this.token,
    this.activeLineId,
    this.userAgent,
    this.adult = false,
    this.note,
    this.lastAccessAt,
    this.movieCount,
    this.seriesCount,
  });

  /// 显示用的名称：没填名称（且服务器也没返回名称）时用地址的主机名
  String get displayName {
    if (name.trim().isNotEmpty) return name.trim();
    final host = lines.isEmpty ? null : Uri.tryParse(lines.first.url.trim())?.host;
    return host == null || host.isEmpty ? '媒体服务器' : host;
  }

  /// 影响连接与请求结果的字段。测速延迟、片量、访问时间等变化不应重建客户端、重新请求服务器。
  String get connectionKey => [
    type.name,
    username,
    password,
    userId,
    token,
    activeLineId,
    userAgent,
    for (final l in lines) '${l.id}|${l.url}|${l.proxied}',
  ].join('\u0001');

  final String id;
  final ServerType type;
  final String name;
  final List<ServerLine> lines;
  final String username;

  /// 保存密码以便令牌失效时自动重新登录。
  /// 存储时放进系统密钥库（见 ConfigStore），配置文件里不保存明文。
  final String password;
  final String? userId;
  final String? token;

  /// null = 自动选线（测速最快）
  final String? activeLineId;

  /// 覆盖全局播放 UA
  final String? userAgent;
  final bool adult;
  final String? note;
  final DateTime? lastAccessAt;
  final int? movieCount;
  final int? seriesCount;

  bool get loggedIn => token != null && userId != null;

  ServerConfig copyWith({
    String? name,
    List<ServerLine>? lines,
    String? username,
    String? password,
    String? userId,
    String? token,
    String? activeLineId,
    bool clearActiveLine = false,
    String? userAgent,
    bool clearUserAgent = false,
    bool? adult,
    String? note,
    DateTime? lastAccessAt,
    int? movieCount,
    int? seriesCount,
    bool clearSession = false,
  }) => ServerConfig(
    id: id,
    type: type,
    name: name ?? this.name,
    lines: lines ?? this.lines,
    username: username ?? this.username,
    password: password ?? this.password,
    userId: clearSession ? null : (userId ?? this.userId),
    token: clearSession ? null : (token ?? this.token),
    activeLineId: clearActiveLine ? null : (activeLineId ?? this.activeLineId),
    userAgent: clearUserAgent ? null : (userAgent ?? this.userAgent),
    adult: adult ?? this.adult,
    note: note ?? this.note,
    lastAccessAt: lastAccessAt ?? this.lastAccessAt,
    movieCount: movieCount ?? this.movieCount,
    seriesCount: seriesCount ?? this.seriesCount,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'name': name,
    'lines': lines.map((l) => l.toJson()).toList(),
    'username': username,
    'password': password,
    'userId': userId,
    'token': token,
    'activeLineId': activeLineId,
    'userAgent': userAgent,
    'adult': adult,
    'note': note,
    'lastAccessAt': lastAccessAt?.toIso8601String(),
    'movieCount': movieCount,
    'seriesCount': seriesCount,
  };

  factory ServerConfig.fromJson(Map<String, dynamic> j) => ServerConfig(
    id: j['id'] as String,
    type: ServerType.parse(j['type'] as String?),
    name: j['name'] as String? ?? '服务器',
    lines: [for (final l in (j['lines'] as List? ?? const [])) ServerLine.fromJson(l as Map<String, dynamic>)],
    username: j['username'] as String? ?? '',
    password: j['password'] as String? ?? '',
    userId: j['userId'] as String?,
    token: j['token'] as String?,
    activeLineId: j['activeLineId'] as String?,
    userAgent: j['userAgent'] as String?,
    adult: j['adult'] as bool? ?? false,
    note: j['note'] as String?,
    lastAccessAt: DateTime.tryParse(j['lastAccessAt'] as String? ?? ''),
    movieCount: j['movieCount'] as int?,
    seriesCount: j['seriesCount'] as int?,
  );
}

/// 反向代理（默认按 emby-reverse-proxy-go 的地址格式改写，见 docs/03-media-servers.md §5.2）。
/// 线路勾选「走反向代理」后，API、图片、视频流全部经过代理（不再区分代理范围）。
class ProxyConfig {
  const ProxyConfig({this.baseUrl = ''});

  /// "完整地址"，如 `https://embyproxy.example.com/proxy/`；空 = 未配置
  final String baseUrl;

  bool get enabled => baseUrl.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {'baseUrl': baseUrl};

  /// 旧版本保存的 scope（代理范围）字段直接忽略
  factory ProxyConfig.fromJson(Map<String, dynamic> j) => ProxyConfig(baseUrl: j['baseUrl'] as String? ?? '');
}

/// Android 播放内核偏好
enum EnginePreference {
  /// ExoPlayer，失败时自动换 mpv
  auto,
  exo,
  mpv;

  static EnginePreference parse(String? s) => values.firstWhere((e) => e.name == s, orElse: () => auto);
}

class PlaybackConfig {
  const PlaybackConfig({
    this.userAgent = '',
    this.uaForApi = false,
    this.clientName = 'Viora',
    this.deviceName = '',
    this.seekStepSeconds = 10,
    this.engine = EnginePreference.auto,
    this.autoFrameRate = true,
    this.tunneling = false,
    this.preload = true,
    this.warmMb = 2,
    this.bufferMb = 256,
    this.clearCacheOnExit = true,
  });

  /// 起播预热量（MB）：片头 / 续播位置 / 片尾合计大约读取这么多
  final int warmMb;

  /// 播放时的预读缓冲上限（MB）。Windows 超过 256MB 时缓存写到磁盘；
  /// Android TV 受内存限制，实际最多使用可用内存的 40%
  final int bufferMb;

  /// 关闭播放器后清除播放缓存（磁盘缓存文件与预加载的数据）
  final bool clearCacheOnExit;

  static const warmChoices = [2, 8, 32, 128];
  static const bufferChoices = [64, 256, 512, 1024, 2048];

  /// 播放预加载：提前取播放信息并预热视频流（会多用少量流量）
  final bool preload;

  /// Android 播放内核（Windows 固定 mpv）
  final EnginePreference engine;

  /// 按片源帧率切换电视刷新率
  final bool autoFrameRate;

  /// 隧道播放
  final bool tunneling;

  /// 全局播放 UA；空 = 使用默认 UA
  final String userAgent;

  /// API 与图片请求也使用播放 UA
  final bool uaForApi;

  /// 上报给 Emby / Jellyfin 的客户端名称（部分服务器按客户端名做白名单）
  final String clientName;

  /// 设备名；空 = 自动（Windows / Android TV）
  final String deviceName;

  final int seekStepSeconds;

  PlaybackConfig copyWith({
    String? userAgent,
    bool? uaForApi,
    String? clientName,
    String? deviceName,
    int? seekStepSeconds,
    EnginePreference? engine,
    bool? autoFrameRate,
    bool? tunneling,
    bool? preload,
    int? warmMb,
    int? bufferMb,
    bool? clearCacheOnExit,
  }) => PlaybackConfig(
    userAgent: userAgent ?? this.userAgent,
    uaForApi: uaForApi ?? this.uaForApi,
    clientName: clientName ?? this.clientName,
    deviceName: deviceName ?? this.deviceName,
    seekStepSeconds: seekStepSeconds ?? this.seekStepSeconds,
    engine: engine ?? this.engine,
    autoFrameRate: autoFrameRate ?? this.autoFrameRate,
    tunneling: tunneling ?? this.tunneling,
    preload: preload ?? this.preload,
    warmMb: warmMb ?? this.warmMb,
    bufferMb: bufferMb ?? this.bufferMb,
    clearCacheOnExit: clearCacheOnExit ?? this.clearCacheOnExit,
  );

  Map<String, dynamic> toJson() => {
    'userAgent': userAgent,
    'uaForApi': uaForApi,
    'clientName': clientName,
    'deviceName': deviceName,
    'seekStepSeconds': seekStepSeconds,
    'engine': engine.name,
    'autoFrameRate': autoFrameRate,
    'tunneling': tunneling,
    'preload': preload,
    'warmMb': warmMb,
    'bufferMb': bufferMb,
    'clearCacheOnExit': clearCacheOnExit,
  };

  factory PlaybackConfig.fromJson(Map<String, dynamic> j) => PlaybackConfig(
    userAgent: j['userAgent'] as String? ?? '',
    uaForApi: j['uaForApi'] as bool? ?? false,
    clientName: (j['clientName'] as String?)?.trim().isNotEmpty == true ? j['clientName'] as String : 'Viora',
    deviceName: j['deviceName'] as String? ?? '',
    seekStepSeconds: j['seekStepSeconds'] as int? ?? 10,
    engine: EnginePreference.parse(j['engine'] as String?),
    autoFrameRate: j['autoFrameRate'] as bool? ?? true,
    tunneling: j['tunneling'] as bool? ?? false,
    preload: j['preload'] as bool? ?? true,
    warmMb: j['warmMb'] as int? ?? 2,
    bufferMb: j['bufferMb'] as int? ?? 256,
    clearCacheOnExit: j['clearCacheOnExit'] as bool? ?? true,
  );
}

/// TMDB（用于补全中文元数据；M4 起也用于首页推荐）
class TmdbConfig {
  const TmdbConfig({this.apiKey = '', this.baseUrl = '', this.useProxy = false});

  /// v3 API Key 或 v4 读取令牌（Read Access Token）
  final String apiKey;

  /// 空 = https://api.themoviedb.org/3；也可以填自建的 TMDB 反代地址
  final String baseUrl;

  /// 通过「反向代理」访问 TMDB
  final bool useProxy;

  /// 构建时内置的读取令牌（CI 用 `--dart-define=VIORA_TMDB_TOKEN=...` 注入）；用户填写的优先
  static const builtinToken = String.fromEnvironment('VIORA_TMDB_TOKEN');

  String get effectiveKey => apiKey.trim().isNotEmpty ? apiKey.trim() : builtinToken;

  bool get enabled => effectiveKey.isNotEmpty;

  String get effectiveBaseUrl {
    final b = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return b.isEmpty ? 'https://api.themoviedb.org/3' : b;
  }

  TmdbConfig copyWith({String? apiKey, String? baseUrl, bool? useProxy}) =>
      TmdbConfig(apiKey: apiKey ?? this.apiKey, baseUrl: baseUrl ?? this.baseUrl, useProxy: useProxy ?? this.useProxy);

  Map<String, dynamic> toJson() => {'apiKey': apiKey, 'baseUrl': baseUrl, 'useProxy': useProxy};

  factory TmdbConfig.fromJson(Map<String, dynamic> j) => TmdbConfig(
    apiKey: j['apiKey'] as String? ?? '',
    baseUrl: j['baseUrl'] as String? ?? '',
    useProxy: j['useProxy'] as bool? ?? false,
  );
}

/// 弹幕（docs/10-danmaku.md）：最多 3 个弹幕服务器（danmu_api，地址格式 `https://{域名}/{token}`）并发搜索
class DanmakuConfig {
  const DanmakuConfig({
    this.enabled = true,
    this.servers = const [],
    this.maxCount = 3000,
    this.fontSize = 34,
    this.opacity = 0.85,
    this.area = 0.5,
    this.speed = 9,
    this.showFixed = true,
    this.convert = DanmakuConvert.none,
    this.colorMode = DanmakuColorMode.none,
    this.blockWords = '',
    this.searchBlockWords = '',
  });

  /// 播放时自动加载并显示弹幕
  final bool enabled;

  /// 弹幕服务器地址（最多 3 个）
  final List<String> servers;

  /// 每集最多显示多少条；0 = 不限。超出时按全片等比例随机剔除
  final int maxCount;

  /// 字号（设计像素）
  final double fontSize;

  /// 不透明度 0~1
  final double opacity;

  /// 滚动弹幕占屏幕高度的比例
  final double area;

  /// 一条滚动弹幕从右到左走完屏幕的秒数
  final double speed;

  /// 显示顶部 / 底部固定弹幕
  final bool showFixed;
  final DanmakuConvert convert;
  final DanmakuColorMode colorMode;

  /// 弹幕内容屏蔽词（逗号分隔）
  final String blockWords;

  /// 搜索结果屏蔽词（逗号分隔），如「解说,手语」
  final String searchBlockWords;

  static const maxServers = 3;
  static const countChoices = [1000, 3000, 5000, 0];

  /// 选项与显示文字（设置页和播放页菜单共用）
  static const fontOptions = [(28.0, '小'), (34.0, '中'), (40.0, '大'), (48.0, '特大')];
  static const opacityOptions = [(0.4, '40%'), (0.6, '60%'), (0.85, '85%'), (1.0, '100%')];
  static const areaOptions = [(0.25, '1/4 屏'), (0.5, '半屏'), (0.75, '3/4 屏'), (1.0, '全屏')];
  static const speedOptions = [(12.0, '慢'), (9.0, '正常'), (6.0, '快')];

  static String labelOf(List<(double, String)> options, double v) =>
      options.where((o) => o.$1 == v).firstOrNull?.$2 ?? '$v';

  /// 已填写的服务器（规范化：补协议、去掉末尾斜杠）
  List<String> get activeServers => [
    for (final s in servers)
      if (normalizeServer(s).isNotEmpty) normalizeServer(s),
  ];

  bool get ready => enabled && activeServers.isNotEmpty;

  static String normalizeServer(String raw) {
    var s = raw.trim().replaceAll(RegExp(r'/+$'), '');
    if (s.isEmpty) return '';
    if (!s.contains('://')) {
      // 局域网 / IP 地址默认 http，域名默认 https
      final host = s.split(RegExp('[:/]')).first;
      final local = RegExp(r'^(\d+\.){3}\d+$').hasMatch(host) || host == 'localhost' || !host.contains('.');
      s = '${local ? 'http' : 'https'}://$s';
    }
    return s;
  }

  DanmakuConfig copyWith({
    bool? enabled,
    List<String>? servers,
    int? maxCount,
    double? fontSize,
    double? opacity,
    double? area,
    double? speed,
    bool? showFixed,
    DanmakuConvert? convert,
    DanmakuColorMode? colorMode,
    String? blockWords,
    String? searchBlockWords,
  }) => DanmakuConfig(
    enabled: enabled ?? this.enabled,
    servers: servers ?? this.servers,
    maxCount: maxCount ?? this.maxCount,
    fontSize: fontSize ?? this.fontSize,
    opacity: opacity ?? this.opacity,
    area: area ?? this.area,
    speed: speed ?? this.speed,
    showFixed: showFixed ?? this.showFixed,
    convert: convert ?? this.convert,
    colorMode: colorMode ?? this.colorMode,
    blockWords: blockWords ?? this.blockWords,
    searchBlockWords: searchBlockWords ?? this.searchBlockWords,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'servers': servers,
    'maxCount': maxCount,
    'fontSize': fontSize,
    'opacity': opacity,
    'area': area,
    'speed': speed,
    'showFixed': showFixed,
    'convert': convert.name,
    'colorMode': colorMode.name,
    'blockWords': blockWords,
    'searchBlockWords': searchBlockWords,
  };

  factory DanmakuConfig.fromJson(Map<String, dynamic> j) => DanmakuConfig(
    enabled: j['enabled'] as bool? ?? true,
    servers: [for (final s in (j['servers'] as List? ?? const [])) s.toString()],
    maxCount: (j['maxCount'] as num?)?.toInt() ?? 3000,
    fontSize: (j['fontSize'] as num?)?.toDouble() ?? 34,
    opacity: (j['opacity'] as num?)?.toDouble() ?? 0.85,
    area: (j['area'] as num?)?.toDouble() ?? 0.5,
    speed: (j['speed'] as num?)?.toDouble() ?? 9,
    showFixed: j['showFixed'] as bool? ?? true,
    convert: DanmakuConvert.parse(j['convert'] as String?),
    colorMode: DanmakuColorMode.parse(j['colorMode'] as String?),
    blockWords: j['blockWords'] as String? ?? '',
    searchBlockWords: j['searchBlockWords'] as String? ?? '',
  );
}

class AppConfig {
  const AppConfig({
    this.servers = const [],
    this.proxy = const ProxyConfig(),
    this.playback = const PlaybackConfig(),
    this.tmdb = const TmdbConfig(),
    this.danmaku = const DanmakuConfig(),
    this.deviceId = '',
  });

  /// 所有服务器的连接键（只在登录、线路、代理、UA 等变化时改变）
  String get serversKey => [for (final s in servers) '${s.id}#${s.connectionKey}'].join('\u0002');

  /// 某台服务器客户端依赖的全部配置
  String clientKey(String serverId) => [
    server(serverId)?.connectionKey,
    proxy.baseUrl,
    playback.userAgent,
    playback.uaForApi,
    playback.clientName,
    playback.deviceName,
    deviceId,
  ].join('\u0003');

  final List<ServerConfig> servers;
  final ProxyConfig proxy;
  final PlaybackConfig playback;
  final TmdbConfig tmdb;
  final DanmakuConfig danmaku;

  /// 每台设备固定的 DeviceId（避免被服务器当成新设备反复占用设备数）
  final String deviceId;

  ServerConfig? server(String id) => servers.where((s) => s.id == id).firstOrNull;

  AppConfig copyWith({
    List<ServerConfig>? servers,
    ProxyConfig? proxy,
    PlaybackConfig? playback,
    TmdbConfig? tmdb,
    DanmakuConfig? danmaku,
    String? deviceId,
  }) => AppConfig(
    servers: servers ?? this.servers,
    proxy: proxy ?? this.proxy,
    playback: playback ?? this.playback,
    tmdb: tmdb ?? this.tmdb,
    danmaku: danmaku ?? this.danmaku,
    deviceId: deviceId ?? this.deviceId,
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'servers': servers.map((s) => s.toJson()).toList(),
    'proxy': proxy.toJson(),
    'playback': playback.toJson(),
    'tmdb': tmdb.toJson(),
    'danmaku': danmaku.toJson(),
    'deviceId': deviceId,
  };

  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
    servers: [for (final s in (j['servers'] as List? ?? const [])) ServerConfig.fromJson(s as Map<String, dynamic>)],
    proxy: ProxyConfig.fromJson(j['proxy'] as Map<String, dynamic>? ?? const {}),
    playback: PlaybackConfig.fromJson(j['playback'] as Map<String, dynamic>? ?? const {}),
    tmdb: TmdbConfig.fromJson(j['tmdb'] as Map<String, dynamic>? ?? const {}),
    danmaku: DanmakuConfig.fromJson(j['danmaku'] as Map<String, dynamic>? ?? const {}),
    deviceId: j['deviceId'] as String? ?? '',
  );
}

final _random = Random.secure();

/// 随机 ID（32 位十六进制）
String newId() => List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
