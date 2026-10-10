enum SegmentSkipMode { auto, button, off }

const segmentProviderDefaults = {
  'theintrodb': 'https://api.theintrodb.org/v3',
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
    this.intro = SegmentSkipMode.button,
    this.recap = SegmentSkipMode.button,
    this.credits = SegmentSkipMode.button,
    this.firstEpisodeException = true,
  });
  final List<SegmentProviderSettings> providers;
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
  }) => SegmentSettings(
    providers: providers ?? this.providers,
    intro: intro ?? this.intro,
    recap: recap ?? this.recap,
    credits: credits ?? this.credits,
    firstEpisodeException: firstEpisodeException ?? this.firstEpisodeException,
  );

  Map<String, Object?> toJson() => {
    'providers': providers.map((p) => p.toJson()).toList(),
    'intro': intro.name,
    'recap': recap.name,
    'credits': credits.name,
    'first_episode_exception': firstEpisodeException,
  };

  factory SegmentSettings.fromJson(Map<String, dynamic> json) {
    SegmentSkipMode mode(String field) =>
        SegmentSkipMode.values.where((m) => m.name == json[field]).firstOrNull ?? SegmentSkipMode.button;
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
          baseUrl: row['base_url'] as String? ?? segmentProviderDefaults[id]!,
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
      intro: mode('intro'),
      recap: mode('recap'),
      credits: mode('credits'),
      firstEpisodeException: json['first_episode_exception'] as bool? ?? true,
    );
  }
}
