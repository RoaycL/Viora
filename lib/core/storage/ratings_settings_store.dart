import 'dart:convert';

import '../../data/config/config_store.dart';
import '../../domain/models/ratings_settings.dart';

/// A single encrypted record makes key changes/clears and preferences atomic.
/// Failure is reported; credentials never fall back to plaintext preferences.
class RatingsSettingsStore {
  RatingsSettingsStore({SecretVault? vault}) : _vault = vault ?? ConfigStore.vault;
  final SecretVault _vault;
  Future<void> _writes = Future<void>.value();
  static const _key = 'viora.ratings.settings.v1';

  Future<RatingsSettings> load() async {
    try {
      await _writes;
      final raw = await _vault.read(_key);
      if (raw == null) return RatingsSettings.defaults();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final settings = RatingsSettings.fromJson(json['settings'] as Map<String, dynamic>);
      final keys = json['keys'] as Map<String, dynamic>? ?? const {};
      return settings.copyWith(
        providers: [for (final p in settings.providers) p.copyWith(apiKey: keys[p.id.name] as String? ?? '')],
      );
    } catch (_) {
      throw const RatingsStorageException('无法读取评分设置，请检查系统安全存储');
    }
  }

  Future<void> save(RatingsSettings settings) {
    final task = _writes.then((_) async {
      try {
        await _vault.write(
          _key,
          jsonEncode({
            'settings': settings.toJson(),
            'keys': {for (final p in settings.providers) p.id.name: p.apiKey},
          }),
        );
      } catch (_) {
        throw const RatingsStorageException('保存失败：系统安全存储不可用，输入的 Key 未保存');
      }
    });
    _writes = task.catchError((Object _) {});
    return task;
  }
}

class RatingsStorageException implements Exception {
  const RatingsStorageException(this.message);
  final String message;
  @override
  String toString() => message;
}
