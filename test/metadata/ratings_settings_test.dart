import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/core/storage/ratings_settings_store.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/data/metadata/ratings_cache.dart';
import 'package:viora/data/metadata/ratings_http.dart';
import 'package:viora/data/sync/config_payload.dart';
import 'package:viora/domain/models/external_rating.dart';
import 'package:viora/domain/models/ratings_settings.dart';
import 'package:viora/features/metadata/ratings_service.dart';

RatingsSettings configured(String key) => RatingsSettings(
  providers: [
    RatingProviderSettings(id: RatingProviderId.omdb, apiKey: key, enabled: true),
    const RatingProviderSettings(id: RatingProviderId.trakt),
  ],
);

class FailingVault extends MemoryVault {
  bool fail = false;
  @override
  Future<void> write(String key, String? value) async {
    if (fail) throw Exception('sensitive error content');
    await super.write(key, value);
  }
}

class DelayedVault extends MemoryVault {
  final started = Completer<void>();
  final release = Completer<void>();
  int writes = 0;
  @override
  Future<void> write(String key, String? value) async {
    writes++;
    if (writes == 1) {
      started.complete();
      await release.future;
    }
    await super.write(key, value);
  }
}

void main() {
  test('a queued clear cannot be overwritten by a slower earlier sync save', () async {
    final vault = DelayedVault();
    final store = RatingsSettingsStore(vault: vault);
    final first = store.save(configured('old'));
    await vault.started.future;
    final clear = store.save(configured(''));
    final read = store.load();
    await Future<void>.delayed(Duration.zero);
    expect(vault.writes, 1);
    vault.release.complete();
    await Future.wait([first, clear]);
    expect((await read).providers.first.apiKey, isEmpty);
    expect(vault.writes, 2);
  });
  test('secure record changes and clears credentials atomically; public JSON has no keys', () async {
    final vault = MemoryVault();
    final store = RatingsSettingsStore(vault: vault);
    await store.save(configured('first-key'));
    expect((await store.load()).providers.first.apiKey, 'first-key');
    await store.save(configured('second-key'));
    expect((await store.load()).providers.first.apiKey, 'second-key');
    expect(jsonEncode(configured('second-key').toJson()), isNot(contains('second-key')));
    await store.save(configured(''));
    expect((await store.load()).providers.first.apiKey, isEmpty);
  });

  test('failed secure write preserves last saved key and reports no credential content', () async {
    final vault = FailingVault();
    final store = RatingsSettingsStore(vault: vault);
    await store.save(configured('old'));
    vault.fail = true;
    await expectLater(
      store.save(configured('new')),
      throwsA(isA<RatingsStorageException>().having((e) => e.toString(), 'message', isNot(contains('sensitive')))),
    );
    expect((await store.load()).providers.first.apiKey, 'old');
    await expectLater(store.save(configured('')), throwsA(isA<RatingsStorageException>()));
    expect((await store.load()).providers.first.apiKey, 'old');
  });

  test('credential normalization supports pasted URL and decimal/hex HTML entities', () {
    expect(normalizeRatingKey(RatingProviderId.omdb, 'http://www.omdbapi.com/?i=tt3896198&apikey=sample'), 'sample');
    expect(normalizeRatingKey(RatingProviderId.trakt, '&#x39;RB3'), '9RB3');
    expect(normalizeRatingKey(RatingProviderId.trakt, '&#57;RB3'), '9RB3');
    expect(() => normalizeRatingKey(RatingProviderId.trakt, 'invalid key'), throwsFormatException);
  });

  test('key/base/proxy changes isolate cached responses without storing raw credentials', () async {
    final cache = MemoryRatingsCache();
    var calls = 0;
    Future<Object?> fetch(Uri _, Map<String, String> _) async {
      calls++;
      return {'Response': 'True', 'Type': 'movie', 'imdbID': 'tt3896198', 'imdbRating': '7.6', 'imdbVotes': '10'};
    }

    const q = RatingQuery(kind: RatingMediaKind.movie, imdbId: 'tt3896198');
    final first = buildRatingsResolver(configured('first-key'), cache: cache, fetcher: fetch);
    await first.resolve(RatingProviderId.omdb, q);
    await first.resolve(RatingProviderId.omdb, q);
    expect(calls, 1);
    final second = buildRatingsResolver(configured('second-key'), cache: cache, fetcher: fetch);
    await second.resolve(RatingProviderId.omdb, q);
    final viaProxy = buildRatingsResolver(
      configured('second-key').copyWith(useProxy: true),
      cache: cache,
      proxy: const ProxyConfig(baseUrl: 'https://proxy.example/prefix'),
      fetcher: fetch,
    );
    await viaProxy.resolve(RatingProviderId.omdb, q);
    expect(calls, 3);
    final serialized = jsonEncode({for (final e in cache.entries.entries) e.key: e.value.toJson()});
    expect(serialized, isNot(contains('first-key')));
    expect(serialized, isNot(contains('second-key')));
  });

  test('API endpoints reject insecure URLs, credentials, query/fragment and retain path prefixes', () {
    for (final url in [
      'http://example.com',
      'https://me:pw@example.com',
      'https://example.com?key=x',
      'https://example.com/#x',
    ]) {
      expect(() => ratingEndpoint(Uri.parse(url), 'ratings'), throwsA(isA<RatingsException>()));
    }
    expect(ratingEndpoint(Uri.parse('https://example.com/proxy/'), 'movies/1/ratings').path, '/proxy/movies/1/ratings');
  });

  test('sync excludes keys by default, keeps receiver consent, and honors explicit clears', () {
    final local = configured('local');
    final normal = buildSyncPayload(const AppConfig(), sections: {SyncSection.ratings}, ratings: local);
    expect(jsonEncode(normal), isNot(contains('local')));
    final exported = buildSyncPayload(
      const AppConfig(),
      sections: {SyncSection.ratings},
      ratings: local.copyWith(syncKeys: true),
    );
    expect(jsonEncode(exported), contains('local'));
    final imported = applyRatingsSync(configured('receiver'), mergeSyncPayload(const AppConfig(), exported));
    expect(imported.providers.first.apiKey, 'local');
    expect(imported.syncKeys, isFalse);
    final withoutKeys = applyRatingsSync(configured('receiver'), mergeSyncPayload(const AppConfig(), normal));
    expect(withoutKeys.providers.first.apiKey, 'receiver');
    final clear = applyRatingsSync(
      local,
      mergeSyncPayload(const AppConfig(), {
        'viora': 1,
        'ratings': {
          'keys': {'omdb': ''},
        },
      }),
    );
    expect(clear.providers.first.apiKey, isEmpty);
    expect(clear.providers.first.enabled, isFalse);
    final fromPhone = applyRatingsSync(
      RatingsSettings.defaults(),
      mergeSyncPayload(const AppConfig(), {
        'viora': 1,
        'ratings': {
          'keys': {'trakt': '&#x39;sample'},
        },
      }),
    );
    expect(fromPhone.providers.last.apiKey, '9sample');
    expect(fromPhone.providers.last.enabled, isTrue);
  });

  test('同步凭据时只发送自己填写的 Key，空 Key 不会清掉对方已填的', () {
    // 本机只填了 OMDb，没填 Trakt
    final partial = configured('mine').copyWith(syncKeys: true);
    final payload = buildSyncPayload(const AppConfig(), sections: {SyncSection.ratings}, ratings: partial);
    final keys = (payload['ratings'] as Map<String, dynamic>)['keys'] as Map<String, dynamic>;
    expect(keys.keys, ['omdb']);
    const theirs = RatingsSettings(
      providers: [
        RatingProviderSettings(id: RatingProviderId.omdb, apiKey: 'theirs', enabled: true),
        RatingProviderSettings(id: RatingProviderId.trakt, apiKey: 'theirs', enabled: true),
      ],
    );
    final receiver = applyRatingsSync(theirs, mergeSyncPayload(const AppConfig(), payload));
    expect(receiver.providers.firstWhere((p) => p.id == RatingProviderId.trakt).apiKey, 'theirs');
    expect(receiver.providers.firstWhere((p) => p.id == RatingProviderId.omdb).apiKey, 'mine');
  });
}
