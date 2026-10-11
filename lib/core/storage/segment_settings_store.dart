import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/segment_settings.dart';

class SegmentSettingsStore {
  SegmentSettingsStore({FlutterSecureStorage? secrets}) : _secrets = secrets ?? const FlutterSecureStorage();
  final FlutterSecureStorage _secrets;
  static const _preferencesKey = 'segments.settings.v1';

  /// 系统密钥库不可用时（部分电视盒子）Key 退回存这里，和服务器密码的处理一致
  static const _fallbackKey = 'segments.keys.fallback.v1';

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
    final fallback = _fallback(prefs);
    final providers = <SegmentProviderSettings>[];
    for (final provider in settings.providers) {
      final secure = await _readKey(provider.id);
      providers.add(provider.copyWith(apiKey: secure.isNotEmpty ? secure : fallback[provider.id] ?? ''));
    }
    return settings.copyWith(providers: providers);
  }

  /// 部分电视盒子的系统密钥库不可用：读不到 Key 时按未填写处理，不影响其他设置和服务器标记
  Future<String> _readKey(String id) async {
    try {
      return await _secrets.read(key: 'segments.key.$id') ?? '';
    } catch (_) {
      return '';
    }
  }

  Map<String, String> _fallback(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_fallbackKey);
      return raw == null ? {} : (jsonDecode(raw) as Map<String, dynamic>).cast<String, String>();
    } on Object {
      return {};
    }
  }

  /// 先写 Key 再写其他设置；密钥库写入失败的 Key 改存进普通配置，不会出现"设置存了、Key 没存"的半保存状态
  Future<void> save(SegmentSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    final fallback = <String, String>{};
    for (final provider in settings.providers) {
      final key = 'segments.key.${provider.id}';
      try {
        if (provider.apiKey.isEmpty) {
          await _secrets.delete(key: key);
        } else {
          await _secrets.write(key: key, value: provider.apiKey);
        }
      } catch (_) {
        if (provider.apiKey.isNotEmpty) fallback[provider.id] = provider.apiKey;
      }
    }
    if (fallback.isEmpty) {
      await prefs.remove(_fallbackKey);
    } else {
      await prefs.setString(_fallbackKey, jsonEncode(fallback));
    }
    await prefs.setString(_preferencesKey, jsonEncode(settings.toJson()));
  }
}
