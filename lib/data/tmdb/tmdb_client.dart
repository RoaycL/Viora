import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../config/config_store.dart';
import '../media/media_models.dart';
import '../media/zh.dart';
import '../net/request_composer.dart';
import 'tmdb_models.dart';

export 'tmdb_models.dart';

/// TMDB 返回的中文元数据
class ZhMeta {
  const ZhMeta({required this.title, required this.overview, required this.genres, this.tagline});

  final String title;
  final String overview;
  final List<String> genres;
  final String? tagline;
}

/// TMDB 客户端（docs/05-metadata-and-segments.md §2）：中文元数据补全 + 首页推荐。
/// 列表接口缓存 6 小时、详情 3 天（内存 + 本地存储），断网时用过期缓存兜底。
class TmdbClient {
  TmdbClient(this.config, this.proxy, {this.kidsMaxAge});

  final TmdbConfig config;
  final ProxyConfig proxy;

  /// 儿童模式的年龄上限：首页推荐行换成适合儿童的电影 / 剧集；null = 不限
  final int? kidsMaxAge;

  static const listTtl = Duration(hours: 6);
  static const detailTtl = Duration(days: 3);
  static final _memory = <String, (DateTime, Map<String, dynamic>)>{};

  @visibleForTesting
  static void clearMemoryCache() => _memory.clear();

  String get _key => config.effectiveKey;
  bool get _isBearer => _key.length > 40;

  Future<Map<String, dynamic>> get(String path, {Map<String, String> query = const {}, Duration? ttl}) async {
    var url = Uri.parse('${config.effectiveBaseUrl}$path')
        .replace(queryParameters: {'language': 'zh-CN', ...query, if (!_isBearer) 'api_key': _key});
    final cacheKey = 'viora.tmdb.${Uri.parse(path).replace(queryParameters: {'language': 'zh-CN', ...query})}';
    if (ttl != null) {
      final hit = await _cached(cacheKey);
      if (hit != null && DateTime.now().difference(hit.$1) < ttl) return hit.$2;
    }
    if (config.useProxy && proxy.enabled) url = proxify(url, proxy.baseUrl);
    try {
      final r =
          await Dio(
            BaseOptions(connectTimeout: const Duration(seconds: 10), receiveTimeout: const Duration(seconds: 15)),
          ).getUri<Map<String, dynamic>>(
            url,
            options: Options(headers: {if (_isBearer) 'Authorization': 'Bearer $_key', 'Accept': 'application/json'}),
          );
      final data = r.data ?? const <String, dynamic>{};
      if (ttl != null) await _store(cacheKey, data);
      return data;
    } catch (_) {
      // 网络失败：有旧缓存就用旧的
      if (ttl != null) {
        final stale = await _cached(cacheKey);
        if (stale != null) return stale.$2;
      }
      rethrow;
    }
  }

  static Future<(DateTime, Map<String, dynamic>)?> _cached(String key) async {
    final mem = _memory[key];
    if (mem != null) return mem;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(key);
      if (raw == null) return null;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final entry = (DateTime.fromMillisecondsSinceEpoch(j['t'] as int), (j['d'] as Map).cast<String, dynamic>());
      return _memory[key] = entry;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _store(String key, Map<String, dynamic> data) async {
    final now = DateTime.now();
    _memory[key] = (now, data);
    try {
      await (await SharedPreferences.getInstance()).setString(
        key,
        jsonEncode({'t': now.millisecondsSinceEpoch, 'd': data}),
      );
    } catch (_) {}
  }

  /// 图片地址（走代理时一并改写）。[size]：w185 / w342 / w500 / w780 / w1280 / original
  String image(String path, {String size = 'w500'}) {
    final url = Uri.parse('https://image.tmdb.org/t/p/$size$path');
    return (config.useProxy && proxy.enabled ? proxify(url, proxy.baseUrl) : url).toString();
  }

  Future<ZhMeta?> details(MediaKind kind, String tmdbId) async {
    final type = switch (kind) {
      MediaKind.movie => 'movie',
      MediaKind.series => 'tv',
      _ => null,
    };
    if (type == null) return null;
    final j = await get('/$type/$tmdbId', ttl: detailTtl);
    final title = (j['title'] ?? j['name'] ?? '') as String;
    return ZhMeta(
      title: title,
      overview: j['overview'] as String? ?? '',
      genres: [for (final g in (j['genres'] as List? ?? const [])) (g as Map)['name'] as String],
      tagline: j['tagline'] as String?,
    );
  }

  List<TmdbTitle> _titles(Map<String, dynamic> j, {bool? isTv}) => [
    for (final r in (j['results'] as List? ?? const []))
      ?TmdbTitle.fromJson((r as Map).cast<String, dynamic>(), isTv: isTv),
  ];

  Future<List<TmdbTitle>> row(TmdbRow row) async {
    if (kidsMaxAge != null) return _kidsRow(row, kidsMaxAge!);
    switch (row) {
      case TmdbRow.trendingDay:
        return _titles(await get('/trending/all/day', ttl: listTtl));
      case TmdbRow.trendingWeek:
        return _titles(await get('/trending/all/week', ttl: listTtl));
      case TmdbRow.nowPlaying:
        return _titles(await get('/movie/now_playing', query: {'region': 'CN'}, ttl: listTtl), isTv: false);
      case TmdbRow.onTheAir:
        return _titles(await get('/tv/on_the_air', ttl: listTtl), isTv: true);
      case TmdbRow.topRatedTv:
        return _titles(await get('/tv/top_rated', ttl: listTtl), isTv: true);
      case TmdbRow.animeToday:
        final now = DateTime.now();
        final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        return _titles(
          await get(
            '/discover/tv',
            query: {
              'with_genres': '16',
              'with_original_language': 'ja',
              'air_date.gte': today,
              'air_date.lte': today,
              'sort_by': 'popularity.desc',
            },
            ttl: listTtl,
          ),
          isTv: true,
        );
    }
  }

  /// 儿童模式的推荐：电影按美国分级（G / PG / PG-13）过滤并限定动画、家庭类；剧集限定少儿、动画、家庭类
  Future<List<TmdbTitle>> _kidsRow(TmdbRow row, int maxAge) async {
    final cert = maxAge <= 7 ? 'G' : (maxAge <= 12 ? 'PG' : 'PG-13');
    Future<List<TmdbTitle>> movies(Map<String, String> extra) async => _titles(
      await get(
        '/discover/movie',
        query: {
          'certification_country': 'US',
          'certification.lte': cert,
          'with_genres': '16|10751',
          'include_adult': 'false',
          ...extra,
        },
        ttl: listTtl,
      ),
      isTv: false,
    );
    Future<List<TmdbTitle>> tv(Map<String, String> extra) async => _titles(
      await get(
        '/discover/tv',
        query: {'with_genres': maxAge <= 7 ? '10762' : '10762|16|10751', 'include_adult': 'false', ...extra},
        ttl: listTtl,
      ),
      isTv: true,
    );
    return switch (row) {
      TmdbRow.trendingDay => movies({'sort_by': 'popularity.desc'}),
      TmdbRow.trendingWeek => tv({'sort_by': 'popularity.desc'}),
      TmdbRow.nowPlaying => movies({'sort_by': 'primary_release_date.desc', 'vote_count.gte': '50'}),
      TmdbRow.onTheAir => tv({'sort_by': 'first_air_date.desc', 'vote_count.gte': '20'}),
      TmdbRow.animeToday => tv({'with_genres': '16', 'sort_by': 'popularity.desc'}),
      TmdbRow.topRatedTv => tv({'sort_by': 'vote_average.desc', 'vote_count.gte': '200'}),
    };
  }

  Future<List<TmdbPerson>> popularPeople() async {
    final j = await get('/person/popular', ttl: listTtl);
    return [
      for (final r in (j['results'] as List? ?? const [])) ?TmdbPerson.fromJson((r as Map).cast<String, dynamic>()),
    ];
  }

  /// 详情：演职员、Logo、相似推荐一次取回
  Future<TmdbTitle?> title(bool isTv, int id) async {
    final j = await get(
      '/${isTv ? 'tv' : 'movie'}/$id',
      query: {
        'append_to_response': '${isTv ? 'aggregate_credits' : 'credits'},recommendations,images,external_ids',
        'include_image_language': 'zh,en,null',
      },
      ttl: detailTtl,
    );
    return TmdbTitle.fromJson(j, isTv: isTv);
  }

  Future<(TmdbPerson?, List<TmdbTitle>)> person(int id) async {
    final j = await get('/person/$id', query: {'append_to_response': 'combined_credits'}, ttl: detailTtl);
    final credits =
        ((j['combined_credits'] as Map?)?['cast'] as List? ?? const [])
            .map((c) => TmdbTitle.fromJson((c as Map).cast<String, dynamic>()))
            .whereType<TmdbTitle>()
            .where((t) => t.posterPath != null)
            .toList()
          ..sort((a, b) => (b.date ?? DateTime(1900)).compareTo(a.date ?? DateTime(1900)));
    final seen = <String>{};
    return (TmdbPerson.fromJson(j), credits.where((t) => seen.add(t.key)).toList());
  }

  /// 按播出平台发现剧集
  Future<List<TmdbTitle>> network(int networkId, {int page = 1}) async => _titles(
    await get(
      '/discover/tv',
      query: {'with_networks': '$networkId', 'sort_by': 'popularity.desc', 'page': '$page'},
      ttl: listTtl,
    ),
    isTv: true,
  );
}

/// 首页 TMDB 推荐行（docs/05 §2.1）
enum TmdbRow { trendingDay, trendingWeek, nowPlaying, onTheAir, animeToday, topRatedTv }

final tmdbClientProvider = Provider<TmdbClient?>((ref) {
  final (tmdb, proxy, parental) = ref.watch(configProvider.select((c) => (c.tmdb, c.proxy, c.parental)));
  return tmdb.enabled ? TmdbClient(tmdb, proxy, kidsMaxAge: parental.enabled ? parental.maxAge : null) : null;
});

final tmdbRowProvider = FutureProvider.family<List<TmdbTitle>, TmdbRow>((ref, row) async {
  final client = ref.watch(tmdbClientProvider);
  if (client == null) return const [];
  try {
    return await client.row(row);
  } catch (e) {
    debugPrint('tmdb $row failed: $e');
    return const [];
  }
});

final tmdbPeopleProvider = FutureProvider<List<TmdbPerson>>((ref) async {
  final client = ref.watch(tmdbClientProvider);
  if (client == null) return const [];
  try {
    return await client.popularPeople();
  } catch (_) {
    return const [];
  }
});

final tmdbTitleProvider = FutureProvider.family<TmdbTitle?, ({bool isTv, int id})>((ref, key) async {
  final client = ref.watch(tmdbClientProvider);
  if (client == null) return null;
  return client.title(key.isTv, key.id);
});

final tmdbPersonProvider = FutureProvider.family<(TmdbPerson?, List<TmdbTitle>), int>((ref, id) async {
  final client = ref.watch(tmdbClientProvider);
  if (client == null) return (null, const <TmdbTitle>[]);
  return client.person(id);
});

final tmdbNetworkProvider = FutureProvider.family<List<TmdbTitle>, int>((ref, id) async {
  final client = ref.watch(tmdbClientProvider);
  if (client == null) return const [];
  final pages = await Future.wait([client.network(id), client.network(id, page: 2)]);
  return [...pages[0], ...pages[1]];
});

typedef ZhKey = ({MediaKind kind, String tmdbId});

/// 按 TMDB ID 取中文元数据（内存缓存；失败返回 null）
final zhMetaProvider = FutureProvider.family<ZhMeta?, ZhKey>((ref, key) async {
  final client = ref.watch(tmdbClientProvider);
  if (client == null) return null;
  try {
    return await client.details(key.kind, key.tmdbId);
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
