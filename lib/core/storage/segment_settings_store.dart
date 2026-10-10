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
      providers.add(provider.copyWith(apiKey: await _readKey(provider.id)));
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

  Future<void> save(SegmentSettings settings) async {
    Object? secretError;
    for (final provider in settings.providers) {
      final key = 'segments.key.${provider.id}';
      try {
        if (provider.apiKey.isEmpty) {
          await _secrets.delete(key: key);
        } else {
          await _secrets.write(key: key, value: provider.apiKey);
        }
      } catch (e) {
        secretError = e;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_preferencesKey, jsonEncode(settings.toJson()));
    // 其他设置已保存；Key 写入失败再报告
    if (secretError != null) throw SegmentKeyStorageException(secretError);
  }
}

class SegmentKeyStorageException implements Exception {
  const SegmentKeyStorageException(this.cause);

  final Object cause;

  @override
  String toString() => '系统安全存储不可用，API Key 未能保存：$cause';
}
