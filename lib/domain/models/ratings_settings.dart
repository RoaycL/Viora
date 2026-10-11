enum RatingProviderId {
  omdb('OMDb', 'https://www.omdbapi.com'),
  trakt('Trakt', 'https://api.trakt.tv');

  const RatingProviderId(this.label, this.defaultUrl);
  final String label;
  final String defaultUrl;

  String get builtinKey => switch (this) {
    omdb => const String.fromEnvironment('VIORA_OMDB_KEY'),
    trakt => const String.fromEnvironment('VIORA_TRAKT_CLIENT_ID'),
  };
}

class RatingProviderSettings {
  const RatingProviderSettings({required this.id, this.enabled = false, this.baseUrl = '', this.apiKey = ''});
  final RatingProviderId id;
  final bool enabled;
  final String baseUrl;
  final String apiKey;
  String get effectiveUrl => baseUrl.isEmpty ? id.defaultUrl : baseUrl;
  String get effectiveKey => apiKey.isEmpty ? id.builtinKey : apiKey;
  bool get configured => effectiveKey.isNotEmpty;

  RatingProviderSettings copyWith({bool? enabled, String? baseUrl, String? apiKey}) => RatingProviderSettings(
    id: id,
    enabled: enabled ?? this.enabled,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
  );

  /// Keys only belong in the vault or explicitly opted-in sync payloads.
  Map<String, Object?> toJson() => {'id': id.name, 'enabled': enabled, 'baseUrl': baseUrl};
}

class RatingsSettings {
  const RatingsSettings({required this.providers, this.useProxy = false, this.syncKeys = false});
  final List<RatingProviderSettings> providers;
  final bool useProxy;
  final bool syncKeys;

  factory RatingsSettings.defaults() => RatingsSettings(
    providers: [
      for (final id in RatingProviderId.values) RatingProviderSettings(id: id, enabled: id.builtinKey.isNotEmpty),
    ],
  );

  RatingsSettings copyWith({List<RatingProviderSettings>? providers, bool? useProxy, bool? syncKeys}) =>
      RatingsSettings(
        providers: providers ?? this.providers,
        useProxy: useProxy ?? this.useProxy,
        syncKeys: syncKeys ?? this.syncKeys,
      );

  Map<String, Object?> toJson() => {
    'providers': providers.map((p) => p.toJson()).toList(),
    'useProxy': useProxy,
    'syncKeys': syncKeys,
  };

  factory RatingsSettings.fromJson(Map<String, dynamic> json) {
    final rows = (json['providers'] as List? ?? const []).whereType<Map<String, dynamic>>().toList();
    final providers = <RatingProviderSettings>[];
    for (final row in rows) {
      final id = RatingProviderId.values.where((id) => id.name == row['id']).firstOrNull;
      if (id == null || providers.any((p) => p.id == id)) continue;
      providers.add(
        RatingProviderSettings(
          id: id,
          enabled: row['enabled'] as bool? ?? false,
          baseUrl: row['baseUrl'] as String? ?? '',
        ),
      );
    }
    for (final id in RatingProviderId.values) {
      if (!providers.any((p) => p.id == id)) providers.add(RatingProviderSettings(id: id));
    }
    return RatingsSettings(
      providers: providers,
      useProxy: json['useProxy'] as bool? ?? false,
      syncKeys: json['syncKeys'] as bool? ?? false,
    );
  }
}

/// Accept a copied OMDb example URL and HTML-encoded Trakt IDs from chat.
String normalizeRatingKey(RatingProviderId id, String input) {
  var key = input
      .trim()
      .replaceAllMapped(RegExp(r'&#(?:x([0-9a-fA-F]+)|([0-9]+));'), (m) {
        final code = int.tryParse(m[1] ?? m[2]!, radix: m[1] == null ? 10 : 16);
        return code != null && code > 0 && code <= 0x10ffff ? String.fromCharCode(code) : m[0]!;
      })
      .replaceAll('&amp;', '&');
  if (id == RatingProviderId.omdb && key.contains('://')) {
    final extracted = Uri.tryParse(key)?.queryParameters['apikey'];
    if (extracted == null || extracted.isEmpty) throw const FormatException('示例链接需要包含 apikey 参数');
    key = extracted;
  }
  if (RegExp(r'\s').hasMatch(key) || key.contains('://') || key.contains('&')) {
    throw const FormatException('请填写 Key 或 Client ID，不要填写其他内容');
  }
  return key;
}
