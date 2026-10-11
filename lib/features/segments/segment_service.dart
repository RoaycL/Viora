import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/storage/segment_settings_store.dart';
import '../../data/config/app_config.dart';
import '../../data/config/config_store.dart';
import '../../data/emby/emby_client.dart';
import '../../data/net/request_composer.dart';
import '../../data/segments/introdb_provider.dart';
import '../../data/segments/publicmetadb_provider.dart';
import '../../data/segments/segment_cache.dart';
import '../../data/segments/server_provider.dart';
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

  /// 界面立即显示新设置；写入失败时恢复成磁盘上实际保存的内容再报错（不会显示未保存的值）
  Future<void> save(SegmentSettings settings) async {
    final store = ref.read(segmentSettingsStoreProvider);
    state = AsyncData(settings);
    try {
      await store.save(settings);
    } catch (_) {
      try {
        state = AsyncData(await store.load());
      } catch (_) {}
      rethrow;
    }
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
  final proxy = ref.watch(configProvider.select((c) => c.proxy));
  return buildSegmentResolver(settings, cache: cache, proxy: proxy);
});

/// 一次播放用的解析器：媒体服务器标记（最高优先级）→ 第三方数据库（按设置顺序）→ 章节名识别（兜底）
Future<SegmentResolver> playbackSegmentResolver(WidgetRef ref, EmbyClient client, String itemId) async {
  final settings = await ref.read(segmentSettingsProvider.future);
  final cache = await ref.read(segmentCacheProvider.future);
  final source = ServerSegmentSource(client, itemId);
  return buildSegmentResolver(
    settings,
    cache: cache,
    proxy: ref.read(configProvider).proxy,
    before: [if (settings.serverMarkers) ServerSegmentProvider(source)],
    after: [if (settings.chapterNames) ChapterNameSegmentProvider(source)],
  );
}

SegmentResolver buildSegmentResolver(
  SegmentSettings settings, {
  SegmentCache? cache,
  ProxyConfig? proxy,
  List<SegmentProvider> before = const [],
  List<SegmentProvider> after = const [],
}) {
  final providers = <SegmentProvider>[...before];
  final viaProxy = settings.useProxy && proxy != null && proxy.enabled;
  for (final config in settings.providers.where((p) => p.enabled)) {
    var baseUrl = Uri.parse(config.baseUrl);
    // 国内网络访问不稳定时经反向代理（emby-reverse-proxy-go 地址格式，保留路径前缀）
    if (viaProxy) baseUrl = proxify(baseUrl, proxy.baseUrl);
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
    'version': 2,
    'proxy': viaProxy ? proxy.baseUrl : null,
    'providers': settings.providers
        .map((p) => {...p.toJson(), 'key_hash': sha256.convert(utf8.encode(p.apiKey)).toString()})
        .toList(),
    'before': before.map((p) => p.id).toList(),
    'after': after.map((p) => p.id).toList(),
  });
  return SegmentResolver(
    providers: providers,
    cache: cache,
    // 不阻塞起播（起播后后台解析），经反代时第三方接口约 1 秒，留足余量
    timeout: const Duration(seconds: 6),
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

String segmentTypeName(SegmentType type) => switch (type) {
  SegmentType.intro => '片头',
  SegmentType.recap => '前情提要',
  SegmentType.credits => '片尾',
  SegmentType.preview => '预告',
};

String segmentProviderName(String id) => switch (id) {
  'server' => '媒体服务器',
  'chapters' => '章节名',
  'theintrodb' => 'TheIntroDB',
  'introdb' => 'IntroDB',
  'publicmetadb' => 'PublicMetaDB',
  _ => id,
};
