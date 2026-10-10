import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/segment_settings.dart';

class SegmentSettingsStore {
  SegmentSettingsStore({FlutterSecureStorage? secrets}) : _secrets = secrets ?? const FlutterSecureStorage();
  final FlutterSecureStorage _secrets;
  static const _preferencesKey = 'segments.settings.v1';

  Future<SegmentSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_preferencesKey);
    var settings = SegmentSettings.defaults();
    if (raw != null) {
      try {
        settings = SegmentSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } on Object {
        /* Recover non-secret preferences independently of stored keys. */
      }
    }
    final providers = <SegmentProviderSettings>[];
    for (final provider in settings.providers) {
      providers.add(provider.copyWith(apiKey: await _secrets.read(key: 'segments.key.${provider.id}') ?? ''));
    }
    return settings.copyWith(providers: providers);
  }

  Future<void> save(SegmentSettings settings) async {
    for (final provider in settings.providers) {
      final key = 'segments.key.${provider.id}';
      if (provider.apiKey.isEmpty) {
        await _secrets.delete(key: key);
      } else {
        await _secrets.write(key: key, value: provider.apiKey);
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_preferencesKey, jsonEncode(settings.toJson()));
  }
}
