import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../config/config_store.dart';
import '../media/media_models.dart';
import '../media/zh.dart';
import '../net/request_composer.dart';

/// TMDB 返回的中文元数据
class ZhMeta {
  const ZhMeta({required this.title, required this.overview, required this.genres, this.tagline});

  final String title;
  final String overview;
  final List<String> genres;
  final String? tagline;
}

/// 最小 TMDB 客户端（M4 扩展为首页推荐）。docs/05-metadata-and-segments.md §2
class TmdbClient {
  TmdbClient(this.config, this.proxy);

  final TmdbConfig config;
  final ProxyConfig proxy;

  bool get _isBearer => config.apiKey.trim().length > 40;

  Future<Map<String, dynamic>> get(String path, {Map<String, String> query = const {}}) async {
    final key = config.apiKey.trim();
    var url = Uri.parse('${config.effectiveBaseUrl}$path')
        .replace(queryParameters: {'language': 'zh-CN', ...query, if (!_isBearer) 'api_key': key});
    if (config.useProxy && proxy.enabled) url = proxify(url, proxy.baseUrl);
    final r =
        await Dio(BaseOptions(connectTimeout: const Duration(seconds: 10), receiveTimeout: const Duration(seconds: 15)))
            .getUri<Map<String, dynamic>>(
              url,
              options: Options(headers: {if (_isBearer) 'Authorization': 'Bearer $key', 'Accept': 'application/json'}),
            );
    return r.data ?? const {};
  }

  Future<ZhMeta?> details(MediaKind kind, String tmdbId) async {
    final type = switch (kind) {
      MediaKind.movie => 'movie',
      MediaKind.series => 'tv',
      _ => null,
    };
    if (type == null) return null;
    final j = await get('/$type/$tmdbId');
    final title = (j['title'] ?? j['name'] ?? '') as String;
    return ZhMeta(
      title: title,
      overview: j['overview'] as String? ?? '',
      genres: [for (final g in (j['genres'] as List? ?? const [])) (g as Map)['name'] as String],
      tagline: j['tagline'] as String?,
    );
  }
}

typedef ZhKey = ({MediaKind kind, String tmdbId});

/// 按 TMDB ID 取中文元数据（内存缓存；失败返回 null）
final zhMetaProvider = FutureProvider.family<ZhMeta?, ZhKey>((ref, key) async {
  final (tmdb, proxy) = ref.watch(configProvider.select((c) => (c.tmdb, c.proxy)));
  if (!tmdb.enabled) return null;
  try {
    return await TmdbClient(tmdb, proxy).details(key.kind, key.tmdbId);
  } catch (_) {
    return null;
  }
});

/// 条目需要从 TMDB 补中文时返回查询键，否则返回 null
ZhKey? zhKeyFor(MediaItem item) {
  final id = item.tmdbId;
  if (id == null || id.isEmpty) return null;
  if (item.kind != MediaKind.movie && item.kind != MediaKind.series) return null;
  if (hasCjk(item.name) && (item.overview == null || item.overview!.isEmpty || hasCjk(item.overview))) return null;
  return (kind: item.kind, tmdbId: id);
}

/// 中文化后的标题 / 简介 / 类型（媒体库已是中文的保持不变）
({String title, String? overview, List<String> genres}) localizedMeta(WidgetRef ref, MediaItem item) {
  final key = zhKeyFor(item);
  final zh = key == null ? null : ref.watch(zhMetaProvider(key)).value;
  String pick(String original, String? candidate) =>
      !hasCjk(original) && candidate != null && candidate.isNotEmpty && hasCjk(candidate) ? candidate : original;
  return (
    title: pick(item.name, zh?.title),
    overview: item.overview == null || item.overview!.isEmpty
        ? (zh?.overview.isNotEmpty == true ? zh!.overview : item.overview)
        : pick(item.overview!, zh?.overview),
    genres: zh != null && zh.genres.isNotEmpty && !item.genres.any(hasCjk) ? zh.genres : item.genres,
  );
}
