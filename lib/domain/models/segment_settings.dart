enum SegmentSkipMode { auto, button, off }

const segmentProviderDefaults = {
  'theintrodb': 'https://api.theintrodb.org/v4',
  'introdb': 'https://api.introdb.app',
  'publicmetadb': 'https://publicmetadb.com',
};

class SegmentProviderSettings {
  const SegmentProviderSettings({required this.id, required this.baseUrl, this.enabled = true, this.apiKey = ''});
  final String id;
  final String baseUrl;
  final bool enabled;
  final String apiKey;

  SegmentProviderSettings copyWith({String? baseUrl, bool? enabled, String? apiKey}) => SegmentProviderSettings(
    id: id,
    baseUrl: baseUrl ?? this.baseUrl,
    enabled: enabled ?? this.enabled,
    apiKey: apiKey ?? this.apiKey,
  );

  /// Non-secret preferences only. API keys belong in the OS credential store.
  Map<String, Object?> toJson() => {'id': id, 'base_url': baseUrl, 'enabled': enabled};
}

class SegmentSettings {
  const SegmentSettings({
    required this.providers,
    this.intro = SegmentSkipMode.auto,
    this.recap = SegmentSkipMode.button,
    this.credits = SegmentSkipMode.auto,
    this.firstEpisodeException = true,
    this.serverMarkers = true,
    this.chapterNames = true,
    this.useProxy = false,
  });
  final List<SegmentProviderSettings> providers;

  /// 使用媒体服务器自带的标记（Emby 章节标记 / Jellyfin 媒体片段），优先级最高
  final bool serverMarkers;

  /// 没有其他数据时按章节名识别（OP / ED / 片头 / 片尾）
  final bool chapterNames;

  /// 第三方数据库经反向代理访问
  final bool useProxy;
  final SegmentSkipMode intro;
  final SegmentSkipMode recap;
  final SegmentSkipMode credits;
  final bool firstEpisodeException;

  factory SegmentSettings.defaults() => SegmentSettings(
    providers: segmentProviderDefaults.entries
        .map((e) => SegmentProviderSettings(id: e.key, baseUrl: e.value, enabled: e.key != 'publicmetadb'))
        .toList(),
  );

  SegmentSettings copyWith({
    List<SegmentProviderSettings>? providers,
    SegmentSkipMode? intro,
    SegmentSkipMode? recap,
    SegmentSkipMode? credits,
    bool? firstEpisodeException,
    bool? serverMarkers,
    bool? chapterNames,
    bool? useProxy,
  }) => SegmentSettings(
    providers: providers ?? this.providers,
    intro: intro ?? this.intro,
    recap: recap ?? this.recap,
    credits: credits ?? this.credits,
    firstEpisodeException: firstEpisodeException ?? this.firstEpisodeException,
    serverMarkers: serverMarkers ?? this.serverMarkers,
    chapterNames: chapterNames ?? this.chapterNames,
    useProxy: useProxy ?? this.useProxy,
  );

  Map<String, Object?> toJson() => {
    'providers': providers.map((p) => p.toJson()).toList(),
    'intro': intro.name,
    'recap': recap.name,
    'credits': credits.name,
    'first_episode_exception': firstEpisodeException,
    'server_markers': serverMarkers,
    'chapter_names': chapterNames,
    'use_proxy': useProxy,
    'defaults_version': defaultsVersion,
  };

  /// 默认值的版本：2 = 片头、片尾默认自动跳过（之前默认「显示按钮」）
  static const defaultsVersion = 2;

  /// [migrateDefaults]：本机保存的设置升级默认值。WebDAV / 局域网同步收到的设置传 false：
  /// 旧版本设备发来的设置不带版本号，里面的「显示按钮」可能是用户在新设备上特意改回的，不能再改成自动跳过
  factory SegmentSettings.fromJson(Map<String, dynamic> json, {bool migrateDefaults = true}) {
    // 旧版本保存的「显示按钮」是当时的默认值：升级时片头、片尾改成新的默认「自动跳过」（只改一次）
    final upgrade = migrateDefaults && (json['defaults_version'] as int? ?? 1) < defaultsVersion;
    SegmentSkipMode mode(String field, {SegmentSkipMode fallback = SegmentSkipMode.button, bool autoNow = false}) {
      final saved = SegmentSkipMode.values.where((m) => m.name == json[field]).firstOrNull;
      if (saved == null) return fallback;
      return upgrade && autoNow && saved == SegmentSkipMode.button ? SegmentSkipMode.auto : saved;
    }

    final providers = <SegmentProviderSettings>[];
    for (final row in (json['providers'] as List? ?? [])) {
      if (row is! Map<String, dynamic>) continue;
      final id = row['id'];
      if (id is! String || !segmentProviderDefaults.containsKey(id) || providers.any((p) => p.id == id)) {
        continue;
      }
      providers.add(
        SegmentProviderSettings(
          id: id,
          baseUrl: _migrateBaseUrl(id, row['base_url'] as String?) ?? segmentProviderDefaults[id]!,
          enabled: row['enabled'] as bool? ?? true,
        ),
      );
    }
    for (final e in segmentProviderDefaults.entries) {
      if (!providers.any((p) => p.id == e.key)) {
        providers.add(SegmentProviderSettings(id: e.key, baseUrl: e.value, enabled: e.key != 'publicmetadb'));
      }
    }
    return SegmentSettings(
      providers: providers,
      intro: mode('intro', fallback: SegmentSkipMode.auto, autoNow: true),
      recap: mode('recap'),
      credits: mode('credits', fallback: SegmentSkipMode.auto, autoNow: true),
      firstEpisodeException: json['first_episode_exception'] as bool? ?? true,
      serverMarkers: json['server_markers'] as bool? ?? true,
      chapterNames: json['chapter_names'] as bool? ?? true,
      useProxy: json['use_proxy'] as bool? ?? false,
    );
  }
}

/// 旧版默认地址升级：TheIntroDB v2 / v3 已冻结并将下线，保存过旧默认地址的改成 v4（自建反代地址不动）
String? _migrateBaseUrl(String id, String? url) {
  if (url == null || id != 'theintrodb') return url;
  final trimmed = url.trim().replaceFirst(RegExp(r'/+$'), '');
  return RegExp(r'^https://api\.theintrodb\.org/v[123]$').hasMatch(trimmed) ? segmentProviderDefaults[id] : url;
}
