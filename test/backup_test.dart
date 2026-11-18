import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/data/sync/config_payload.dart';
import 'package:viora/domain/models/ratings_settings.dart';
import 'package:viora/features/metadata/ratings_service.dart';
import 'package:viora/features/settings/support_actions.dart';

class _UnreadableVault extends MemoryVault {
  @override
  Future<String?> read(String key) async => throw Exception('unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ConfigStore.vault = MemoryVault();
  });

  for (final syncKeys in [false, true]) {
    test('备份包含评分设置，凭据导出遵守 syncKeys=$syncKeys', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final settings = RatingsSettings(
        providers: const [
          RatingProviderSettings(
            id: RatingProviderId.omdb,
            enabled: true,
            apiKey: 'private-key',
            baseUrl: 'https://ratings.example.com',
          ),
        ],
        useProxy: true,
        syncKeys: syncKeys,
      );
      await container.read(ratingsSettingsProvider.future);
      await container.read(ratingsSettingsProvider.notifier).save(settings);
      final backup = await buildBackupPayload(container);
      final ratings = backup['ratings'] as Map;
      expect((ratings['settings'] as Map)['useProxy'], isTrue);
      final omdb = ((ratings['settings'] as Map)['providers'] as List).firstWhere((p) => p['id'] == 'omdb') as Map;
      expect(omdb['baseUrl'], 'https://ratings.example.com');
      if (syncKeys) {
        expect((ratings['keys'] as Map)['omdb'], 'private-key');
      } else {
        expect(ratings.containsKey('keys'), isFalse);
      }
      final merged = mergeSyncPayload(container.read(configProvider), backup);
      final restored = applyRatingsSync(RatingsSettings.defaults(), merged);
      expect(restored.useProxy, isTrue);
      expect(restored.providers.first.baseUrl, 'https://ratings.example.com');
      expect(restored.providers.first.apiKey, syncKeys ? 'private-key' : '');
    });
  }

  test('无法读取评分设置时报告备份失败，不生成悄悄遗漏设置的备份', () async {
    ConfigStore.vault = _UnreadableVault();
    final container = ProviderContainer(retry: (_, _) => null);
    addTearDown(container.dispose);
    await expectLater(buildBackupPayload(container), throwsException);
  });
}
