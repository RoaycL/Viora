import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../data/metadata/rating_provider.dart';
import '../../data/metadata/ratings_cache.dart';
import '../../data/metadata/ratings_http.dart';
import '../models/external_rating.dart';
import '../models/ratings_settings.dart';

/// Resolve each provider independently, so a slow/failing source never blocks
/// other sources. Shared requests, per-provider backoff, and offline stale data.
class RatingsResolver {
  RatingsResolver({
    required this.providers,
    required this.cache,
    required this.namespace,
    DateTime Function()? now,
    this.timeout = const Duration(seconds: 10),
  }) : _now = now ?? DateTime.now;
  final Map<RatingProviderId, RatingProvider> providers;
  final RatingsCache cache;
  final String namespace;
  final Duration timeout;
  final DateTime Function() _now;
  final _pending = <String, Future<RatingsResult>>{};
  final _backoff = <RatingProviderId, DateTime>{};
  final _active = <RatingProviderId, List<Future<void>>>{};
  static const positiveTtl = Duration(hours: 24);
  static const negativeTtl = Duration(hours: 6);

  Future<RatingsResult> resolve(RatingProviderId id, RatingQuery query) {
    final provider = providers[id];
    if (provider == null) return Future.value(const RatingsResult(RatingsData()));
    if (!provider.supports(query)) {
      return Future.value(
        RatingsResult(
          const RatingsData(),
          error: id == RatingProviderId.omdb ? '缺少 IMDb ID，无法查询' : '缺少作品 ID 或剧集季集信息',
          unsupported: true,
        ),
      );
    }
    final key = sha256.convert(utf8.encode('$namespace/${id.name}/${query.identity}')).toString();
    return _pending.putIfAbsent(key, () async {
      try {
        return await _resolve(provider, key, query);
      } finally {
        _pending.remove(key);
      }
    });
  }

  Future<RatingsResult> _resolve(RatingProvider provider, String key, RatingQuery query) async {
    RatingsCacheEntry? cached;
    try {
      cached = await cache.read(key);
    } catch (_) {
      /* Recover corrupt/unavailable cache. */
    }
    if (cached != null) {
      final age = _now().difference(cached.fetchedAt);
      if (!age.isNegative && age < (cached.data.isEmpty ? negativeTtl : positiveTtl)) {
        return RatingsResult(cached.data, fetchedAt: cached.fetchedAt);
      }
    }
    try {
      if (_backoff[provider.id]?.isAfter(_now()) == true) {
        throw const RatingsException('请求额度已达上限，请稍后重试');
      }
      final data = await _fetch(provider, query);
      final at = _now();
      try {
        await cache.write(key, RatingsCacheEntry(at, data));
      } catch (_) {
        /* Cache is optional. */
      }
      return RatingsResult(data, fetchedAt: at);
    } catch (e) {
      if (e is RatingsException && e.retryAfter != null) _backoff[provider.id] = _now().add(e.retryAfter!);
      return RatingsResult(
        cached?.data ?? const RatingsData(),
        fetchedAt: cached?.fetchedAt,
        stale: cached != null,
        error: e is RatingsException ? e.message : '评分查询失败，请检查网络或服务响应',
      );
    }
  }

  Future<RatingsData> _fetch(RatingProvider provider, RatingQuery query) async {
    final active = _active.putIfAbsent(provider.id, () => []);
    while (active.length >= 2) {
      await Future.any(active).timeout(timeout);
    }
    // Recheck after waiting: an earlier request may have imposed backoff.
    if (_backoff[provider.id]?.isAfter(_now()) == true) {
      throw const RatingsException('请求额度已达上限，请稍后重试');
    }
    final finished = Completer<void>();
    active.add(finished.future);
    try {
      return await provider.fetch(query).timeout(timeout);
    } finally {
      active.remove(finished.future);
      finished.complete();
    }
  }
}
