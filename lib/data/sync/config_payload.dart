import '../../domain/models/segment_settings.dart';
import '../config/app_config.dart';

/// 局域网同步配置（docs/11-sync.md）：电视开一个临时入口，手机网页或 Windows 把配置推过去。
///
/// 传输格式：
/// ```json
/// {"viora": 1, "from": "Windows · 书房",
///  "servers": [{"type": "emby", "name": "", "lines": [{"name": "主线路", "url": "https://…", "proxied": false}],
///               "username": "", "password": "", "userAgent": null, "adult": false}],
///  "proxy": {...}, "playback": {...}, "tmdb": {...}, "danmaku": {...},
///  "segments": {"keys": {"theintrodb": "…"}, "settings": {...}}}
/// ```
/// 每一部分都可以省略；proxy / playback / tmdb / danmaku 只覆盖带过来的字段（手机网页只填了几项也没问题）。
/// 不传登录令牌：令牌和设备绑定，电视收到后用账号密码重新登录。
enum SyncSection {
  servers('媒体服务器', '地址、线路、账号密码'),
  network('反向代理与播放 UA', '反代地址、播放 UA、客户端名称'),
  tmdb('TMDB', 'API Key、自定义地址'),
  danmaku('弹幕', '弹幕服务器、显示设置、屏蔽词'),
  segments('片头片尾', '数据源开关与 API Key');

  const SyncSection(this.label, this.detail);
  final String label;
  final String detail;
}

const syncPayloadVersion = 1;

/// 按勾选的部分打包本机配置（Windows → 电视）
Map<String, dynamic> buildSyncPayload(
  AppConfig c, {
  required Set<SyncSection> sections,
  SegmentSettings? segments,
  String from = '',
}) => {
  'viora': syncPayloadVersion,
  'from': from,
  if (sections.contains(SyncSection.servers))
    'servers': [
      for (final s in c.servers)
        {
          'type': s.type.name,
          'name': s.name,
          'lines': [
            for (final l in s.lines) {'name': l.name, 'url': l.url, 'proxied': l.proxied},
          ],
          'username': s.username,
          'password': s.password,
          'userAgent': s.userAgent,
          'adult': s.adult,
          'aggregate': s.aggregate,
        },
    ],
  if (sections.contains(SyncSection.network)) ...{
    'proxy': c.proxy.toJson(),
    'playback': {
      'userAgent': c.playback.userAgent,
      'uaForApi': c.playback.uaForApi,
      'clientName': c.playback.clientName,
    },
  },
  if (sections.contains(SyncSection.tmdb)) 'tmdb': c.tmdb.toJson(),
  if (sections.contains(SyncSection.danmaku)) 'danmaku': c.danmaku.toJson(),
  if (sections.contains(SyncSection.segments) && segments != null)
    'segments': {
      'settings': segments.toJson(),
      'keys': {
        for (final p in segments.providers)
          if (p.apiKey.isNotEmpty) p.id: p.apiKey,
      },
    },
};

/// 合并结果
class SyncMergeResult {
  const SyncMergeResult({
    required this.config,
    required this.changedServerIds,
    required this.summary,
    this.segmentKeys = const {},
    this.segmentSettings,
  });

  final AppConfig config;

  /// 新增或改了地址 / 账号的服务器：需要重新测速、登录
  final List<String> changedServerIds;

  /// 给用户看的结果，如「新增服务器 2 台」
  final List<String> summary;
  final Map<String, String> segmentKeys;
  final Map<String, dynamic>? segmentSettings;

  bool get isEmpty => summary.isEmpty;
}

String _withScheme(String url) => url.contains('://') ? url : 'http://$url';

String _norm(String url) => url.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');

/// 把收到的配置合并进本机配置：服务器按「类型 + 第一条地址 + 用户名」对上的更新，其余新增；
/// 其他部分只覆盖带过来的字段。格式不对时抛 [FormatException]。
SyncMergeResult mergeSyncPayload(AppConfig c, Map<String, dynamic> p) {
  if (p['viora'] is! num) throw const FormatException('不是 Viora 的配置');
  var config = c;
  final summary = <String>[];
  final changed = <String>[];

  final servers = p['servers'];
  if (servers is List && servers.isNotEmpty) {
    final list = [...config.allServers];
    var added = 0, updated = 0;
    for (final raw in servers.whereType<Map<String, dynamic>>()) {
      final lines = [
        for (final (i, l) in (raw['lines'] as List? ?? const []).whereType<Map<String, dynamic>>().indexed)
          if ((l['url'] as String? ?? '').trim().isNotEmpty)
            ServerLine(
              id: newId(),
              name: (l['name'] as String?)?.trim().isNotEmpty == true ? l['name'] as String : '线路 ${i + 1}',
              // 没写协议时按 http（和添加服务器页「使用 HTTPS」关闭时一致）
              url: _withScheme((l['url'] as String).trim()),
              proxied: l['proxied'] as bool? ?? false,
            ),
      ];
      if (lines.isEmpty) continue;
      final type = ServerType.parse(raw['type'] as String?);
      final username = (raw['username'] as String? ?? '').trim();
      final password = raw['password'] as String? ?? '';
      final name = (raw['name'] as String? ?? '').trim();
      final ua = (raw['userAgent'] as String?)?.trim();
      final i = list.indexWhere(
        (s) =>
            s.type == type &&
            s.username == username &&
            s.lines.isNotEmpty &&
            lines.any((l) => s.lines.any((x) => _norm(x.url) == _norm(l.url))),
      );
      if (i >= 0) {
        final old = list[i];
        final credentials = old.password != password;
        list[i] = old.copyWith(
          name: name.isEmpty ? null : name,
          lines: lines,
          password: password,
          userAgent: ua?.isEmpty ?? true ? null : ua,
          clearUserAgent: ua?.isEmpty ?? true,
          adult: raw['adult'] as bool?,
          aggregate: raw['aggregate'] as bool?,
          clearActiveLine: true,
          clearSession: credentials,
        );
        changed.add(old.id);
        updated++;
      } else {
        final s = ServerConfig(
          id: newId(),
          type: type,
          name: name,
          lines: lines,
          username: username,
          password: password,
          userAgent: ua?.isEmpty ?? true ? null : ua,
          adult: raw['adult'] as bool? ?? false,
          aggregate: raw['aggregate'] as bool? ?? true,
        );
        list.add(s);
        changed.add(s.id);
        added++;
      }
    }
    config = config.copyWith(servers: list);
    if (added > 0) summary.add('新增服务器 $added 台');
    if (updated > 0) summary.add('更新服务器 $updated 台');
  }

  Map<String, dynamic>? section(String key) => p[key] is Map<String, dynamic> ? p[key] as Map<String, dynamic> : null;
  if (section('proxy') case final m?) {
    config = config.copyWith(proxy: ProxyConfig.fromJson({...config.proxy.toJson(), ...m}));
    summary.add('反向代理');
  }
  if (section('playback') case final m?) {
    config = config.copyWith(playback: PlaybackConfig.fromJson({...config.playback.toJson(), ...m}));
    summary.add('播放 UA');
  }
  if (section('tmdb') case final m?) {
    config = config.copyWith(tmdb: TmdbConfig.fromJson({...config.tmdb.toJson(), ...m}));
    summary.add('TMDB');
  }
  if (section('danmaku') case final m?) {
    config = config.copyWith(danmaku: DanmakuConfig.fromJson({...config.danmaku.toJson(), ...m}));
    summary.add('弹幕');
  }
  final seg = section('segments');
  final keys = <String, String>{
    for (final e in (seg?['keys'] as Map<String, dynamic>? ?? const {}).entries)
      if (e.value is String && (e.value as String).trim().isNotEmpty) e.key: (e.value as String).trim(),
  };
  final segSettings = seg?['settings'] as Map<String, dynamic>?;
  if (keys.isNotEmpty || segSettings != null) summary.add('片头片尾');

  return SyncMergeResult(
    config: config,
    changedServerIds: changed,
    summary: summary,
    segmentKeys: keys,
    segmentSettings: segSettings,
  );
}

/// 把收到的片头片尾设置 / Key 应用到本机设置上（Key 填了的数据源同时打开）
SegmentSettings applySegmentSync(SegmentSettings current, SyncMergeResult r) {
  var s = r.segmentSettings == null ? current : SegmentSettings.fromJson(r.segmentSettings!);
  // 设置里不含 Key：先保留本机已有的 Key
  s = s.copyWith(
    providers: [
      for (final p in s.providers)
        p.copyWith(apiKey: current.providers.where((x) => x.id == p.id).firstOrNull?.apiKey ?? ''),
    ],
  );
  if (r.segmentKeys.isEmpty) return s;
  return s.copyWith(
    providers: [
      for (final p in s.providers)
        r.segmentKeys.containsKey(p.id) ? p.copyWith(apiKey: r.segmentKeys[p.id], enabled: true) : p,
    ],
  );
}
