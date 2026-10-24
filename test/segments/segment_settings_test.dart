import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/core/storage/segment_settings_store.dart';
import 'package:viora/data/segments/segment_cache.dart';
import 'package:viora/domain/models/segment.dart';
import 'package:viora/domain/models/segment_settings.dart';
import 'package:viora/domain/usecases/segment_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('default skip policies and optional-key providers follow the specification', () {
    final settings = SegmentSettings.defaults();
    expect(settings.intro, SegmentSkipMode.button);
    expect(settings.recap, SegmentSkipMode.button);
    expect(settings.credits, SegmentSkipMode.button);
    expect(settings.firstEpisodeException, isTrue);
    expect(settings.providers.map((p) => p.id), ['theintrodb', 'introdb', 'publicmetadb']);
    expect(settings.providers.last.enabled, isFalse);
  });

  test('settings persist keys only in secure storage; priority and modes round-trip', () async {
    final store = SegmentSettingsStore();
    final original = SegmentSettings.defaults();
    final settings = original.copyWith(
      intro: SegmentSkipMode.auto,
      recap: SegmentSkipMode.off,
      firstEpisodeException: false,
      providers: [
        original.providers.last.copyWith(enabled: true, apiKey: 'secret-pmdb-key'),
        original.providers.first.copyWith(baseUrl: 'https://proxy.example/v3', apiKey: 'secret-tidb-key'),
        original.providers[1],
      ],
    );
    await store.save(settings);
    final loaded = await store.load();
    expect(loaded.providers.map((p) => p.id), ['publicmetadb', 'theintrodb', 'introdb']);
    expect(loaded.providers.first.apiKey, 'secret-pmdb-key');
    expect(loaded.providers[1].baseUrl, 'https://proxy.example/v3');
    expect(loaded.intro, SegmentSkipMode.auto);
    expect(loaded.recap, SegmentSkipMode.off);
    expect(loaded.firstEpisodeException, isFalse);
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      expect(prefs.get(key).toString(), isNot(contains('secret-')));
    }
    expect(jsonEncode(settings.toJson()), isNot(contains('secret-')));
  });

  test('clearing an API key removes its previous encrypted value', () async {
    final store = SegmentSettingsStore();
    final settings = SegmentSettings.defaults();
    await store.save(
      settings.copyWith(
        providers: [
          settings.providers.first.copyWith(apiKey: 'old-key'),
          ...settings.providers.skip(1),
        ],
      ),
    );
    await store.save(settings);
    expect((await store.load()).providers.first.apiKey, isEmpty);
  });

  test('malformed preferences reset policies without losing existing secure keys', () async {
    SharedPreferences.setMockInitialValues({'segments.settings.v1': '[1,2]'});
    FlutterSecureStorage.setMockInitialValues({'segments.key.introdb': 'preserved'});
    final loaded = await SegmentSettingsStore().load();
    expect(loaded.intro, SegmentSkipMode.button);
    expect(loaded.providers[1].apiKey, 'preserved');
  });

  test('bounded file cache survives process recreation and corrupt data is recoverable', () async {
    final dir = await Directory.systemTemp.createTemp('viora-segments-test-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/cache.json');
    final first = FileSegmentCache(file);
    final entry = SegmentCacheEntry(DateTime.utc(2026, 10, 10), [
      const SegmentCandidate(type: SegmentType.credits, start: Duration(seconds: 2900), end: null, provider: 'introdb'),
    ]);
    await first.write('hashed-key', entry);
    final second = FileSegmentCache(file);
    final hit = await second.read('hashed-key');
    expect(hit!.candidates.single.end, isNull);
    expect(hit.fetchedAt, entry.fetchedAt);
    await file.writeAsString('[1,2]');
    await expectLater(second.read('hashed-key'), throwsFormatException);
    await second.write('new-key', entry);
    expect((await second.read('new-key'))!.candidates.single.provider, 'introdb');
  });

  test('系统密钥库不可用：Key 退回存进普通配置，保存不报错、重启后还在', () async {
    final store = SegmentSettingsStore(secrets: _BrokenSecrets());
    final defaults = SegmentSettings.defaults();
    final settings = defaults.copyWith(
      intro: SegmentSkipMode.auto,
      providers: [for (final p in defaults.providers) p.id == 'theintrodb' ? p.copyWith(apiKey: 'k-1') : p],
    );
    await store.save(settings);
    final loaded = await SegmentSettingsStore(secrets: _BrokenSecrets()).load();
    expect(loaded.intro, SegmentSkipMode.auto);
    expect(loaded.providers.firstWhere((p) => p.id == 'theintrodb').apiKey, 'k-1');
  });

  test('saved TheIntroDB v3 default address is upgraded to v4; custom proxies are kept', () {
    final old = SegmentSettings.fromJson({
      'providers': [
        {'id': 'theintrodb', 'base_url': 'https://api.theintrodb.org/v3/', 'enabled': true},
        {'id': 'introdb', 'base_url': 'https://my-proxy.example/introdb', 'enabled': true},
      ],
    });
    expect(old.providers.firstWhere((p) => p.id == 'theintrodb').baseUrl, 'https://api.theintrodb.org/v4');
    expect(old.providers.firstWhere((p) => p.id == 'introdb').baseUrl, 'https://my-proxy.example/introdb');
    final proxied = SegmentSettings.fromJson({
      'providers': [
        {'id': 'theintrodb', 'base_url': 'https://my-proxy.example/theintrodb/v3', 'enabled': true},
      ],
    });
    expect(proxied.providers.firstWhere((p) => p.id == 'theintrodb').baseUrl, 'https://my-proxy.example/theintrodb/v3');
  });
}

class _BrokenSecrets extends FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw Exception('keystore unavailable');

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw Exception('keystore unavailable');

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw Exception('keystore unavailable');
}
