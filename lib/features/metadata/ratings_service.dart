import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/storage/ratings_settings_store.dart';
import '../../data/config/app_config.dart';
import '../../data/config/config_store.dart';
import '../../data/metadata/omdb_provider.dart';
import '../../data/metadata/rating_provider.dart';
import '../../data/metadata/ratings_cache.dart';
import '../../data/metadata/ratings_http.dart';
import '../../data/metadata/trakt_provider.dart';
import '../../data/net/request_composer.dart';
import '../../domain/models/external_rating.dart';
import '../../domain/models/ratings_settings.dart';
import '../../domain/usecases/ratings_resolver.dart';

final ratingsSettingsStoreProvider = Provider<RatingsSettingsStore>((ref) => RatingsSettingsStore());
final ratingsSettingsProvider = AsyncNotifierProvider<RatingsSettingsController, RatingsSettings>(
  RatingsSettingsController.new,
);

class RatingsSettingsController extends AsyncNotifier<RatingsSettings> {
  @override
  Future<RatingsSettings> build() => ref.read(ratingsSettingsStoreProvider).load();
  Future<void> save(RatingsSettings settings) async {
    await ref.read(ratingsSettingsStoreProvider).save(settings);
    state = AsyncData(settings);
  }
}

final ratingsCacheProvider = FutureProvider<RatingsCache>((ref) async {
  try {
    final dir = await getApplicationSupportDirectory();
    return FileRatingsCache(File('${dir.path}/ratings_cache_v1.json'));
  } catch (_) {
    return MemoryRatingsCache();
  }
});

final ratingsResolverProvider = FutureProvider<RatingsResolver>((ref) async {
  final settingsFuture = ref.watch(ratingsSettingsProvider.future);
  final proxy = ref.watch(configProvider.select((c) => c.proxy));
  final cacheFuture = ref.watch(ratingsCacheProvider.future);
  final settings = await settingsFuture;
  final cache = await cacheFuture;
  return buildRatingsResolver(settings, cache: cache, proxy: proxy);
});

RatingsResolver buildRatingsResolver(
  RatingsSettings settings, {
  required RatingsCache cache,
  ProxyConfig proxy = const ProxyConfig(),
  RatingJsonFetcher? fetcher,
}) {
  final viaProxy = settings.useProxy && proxy.enabled;
  final upstream = fetcher ?? fetchRatingJson;
  Future<Object?> fetch(Uri uri, Map<String, String> headers) {
    final target = viaProxy ? proxify(uri, proxy.baseUrl) : uri;
    if (target.scheme != 'https' || target.userInfo.isNotEmpty) {
      throw const RatingsException('评分反向代理需要使用 HTTPS');
    }
    return upstream(target, headers);
  }

  final providers = <RatingProviderId, RatingProvider>{};
  for (final p in settings.providers.where((p) => p.enabled && p.configured)) {
    switch (p.id) {
      case RatingProviderId.omdb:
        providers[p.id] = OmdbProvider(apiKey: p.effectiveKey, baseUrl: Uri.parse(p.effectiveUrl), fetcher: fetch);
      case RatingProviderId.trakt:
        providers[p.id] = TraktProvider(clientId: p.effectiveKey, baseUrl: Uri.parse(p.effectiveUrl), fetcher: fetch);
    }
  }
  final signature = jsonEncode({
    'v': 1,
    'settings': settings.toJson(),
    'proxy': viaProxy ? proxy.baseUrl : null,
    'keys': {for (final p in settings.providers) p.id.name: sha256.convert(utf8.encode(p.effectiveKey)).toString()},
  });
  return RatingsResolver(
    providers: providers,
    cache: cache,
    namespace: sha256.convert(utf8.encode(signature)).toString(),
  );
}

typedef ProviderRatingQuery = ({RatingProviderId provider, RatingQuery query});
final externalRatingsProvider = FutureProvider.autoDispose.family<RatingsResult, ProviderRatingQuery>((ref, key) async {
  final resolver = await ref.watch(ratingsResolverProvider.future);
  return resolver.resolve(key.provider, key.query);
});
