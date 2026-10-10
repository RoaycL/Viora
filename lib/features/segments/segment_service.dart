import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/storage/segment_settings_store.dart';
import '../../data/segments/introdb_provider.dart';
import '../../data/segments/publicmetadb_provider.dart';
import '../../data/segments/segment_cache.dart';
import '../../data/segments/segment_provider.dart';
import '../../data/segments/theintrodb_provider.dart';
import '../../domain/models/segment.dart';
import '../../domain/models/segment_settings.dart';
import '../../domain/usecases/segment_resolver.dart';

final segmentSettingsStoreProvider = Provider<SegmentSettingsStore>((ref) => SegmentSettingsStore());
final segmentSettingsProvider = AsyncNotifierProvider<SegmentSettingsController, SegmentSettings>(
  SegmentSettingsController.new,
);

class SegmentSettingsController extends AsyncNotifier<SegmentSettings> {
  @override
  Future<SegmentSettings> build() => ref.read(segmentSettingsStoreProvider).load();

  Future<void> save(SegmentSettings settings) async {
    await ref.read(segmentSettingsStoreProvider).save(settings);
    state = AsyncData(settings);
  }
}

final segmentCacheProvider = FutureProvider<SegmentCache>((ref) async {
  try {
    final directory = await getApplicationSupportDirectory();
    return FileSegmentCache(File('${directory.path}/segment_cache_v1.json'));
  } on Exception {
    return MemorySegmentCache();
  }
});

final segmentResolverProvider = FutureProvider<SegmentResolver>((ref) async {
  final settings = await ref.watch(segmentSettingsProvider.future);
  final cache = await ref.watch(segmentCacheProvider.future);
  return buildSegmentResolver(settings, cache: cache);
});

SegmentResolver buildSegmentResolver(
  SegmentSettings settings, {
  SegmentCache? cache,
  List<SegmentProvider> before = const [],
  List<SegmentProvider> after = const [],
}) {
  final providers = <SegmentProvider>[...before];
  for (final config in settings.providers.where((p) => p.enabled)) {
    final baseUrl = Uri.parse(config.baseUrl);
    switch (config.id) {
      case 'theintrodb':
        providers.add(TheIntroDbProvider(baseUrl: baseUrl, apiKey: config.apiKey));
      case 'introdb':
        providers.add(IntroDbProvider(baseUrl: baseUrl, apiKey: config.apiKey));
      case 'publicmetadb':
        if (config.apiKey.isNotEmpty) {
          providers.add(PublicMetaDbProvider(baseUrl: baseUrl, apiKey: config.apiKey));
        }
    }
  }
  providers.addAll(after);
  // A source/key/order change must not reuse a previous user's cached result.
  final signature = jsonEncode({
    'version': 1,
    'providers': settings.providers
        .map((p) => {...p.toJson(), 'key_hash': sha256.convert(utf8.encode(p.apiKey)).toString()})
        .toList(),
    'before': before.map((p) => p.id).toList(),
    'after': after.map((p) => p.id).toList(),
  });
  return SegmentResolver(
    providers: providers,
    cache: cache,
    cacheNamespace: sha256.convert(utf8.encode(signature)).toString(),
  );
}

/// Application entry point for a real item's playback metadata or a settings
/// lookup. Movie TMDB IDs / episode series IDs must come from the media server.
final segmentResolutionProvider = FutureProvider.autoDispose.family<SegmentResolution, SegmentQuery>((
  ref,
  query,
) async {
  final resolver = await ref.watch(segmentResolverProvider.future);
  return resolver.resolve(query);
});
