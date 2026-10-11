import 'dart:async';
import 'dart:convert';

import '../../data/segments/segment_http.dart';
import '../../data/segments/segment_provider.dart';
import '../models/segment.dart';

class SegmentCacheEntry {
  const SegmentCacheEntry(this.fetchedAt, this.candidates);
  final DateTime fetchedAt;
  final List<SegmentCandidate> candidates;
}

abstract interface class SegmentCache {
  Future<SegmentCacheEntry?> read(String key);
  Future<void> write(String key, SegmentCacheEntry entry);
}

enum SegmentFailure { timeout, unauthorized, rateLimited, unavailable, invalidResponse }

class SegmentResolution {
  const SegmentResolution({required this.segments, this.failures = const {}, this.fromCache = false});
  final List<Segment> segments;
  final Map<String, SegmentFailure> failures;
  final bool fromCache;
}

/// One independent, bounded request per provider; array order defines priority.
class SegmentResolver {
  SegmentResolver({
    required this.providers,
    this.cache,
    this.cacheNamespace = '',
    this.timeout = const Duration(seconds: 3),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final List<SegmentProvider> providers;
  final SegmentCache? cache;
  final String cacheNamespace;
  final Duration timeout;
  final DateTime Function() _now;

  /// [onPartial]：某种片段已经确定（比它优先的来源都已返回）就先发布，不必等慢的来源超时；
  /// 最终结果仍由返回值给出。命中缓存时不调用。
  Future<SegmentResolution> resolve(SegmentQuery query, {void Function(SegmentResolution partial)? onPartial}) async {
    if (!query.canLookup) return const SegmentResolution(segments: []);
    final key = '$cacheNamespace:${jsonEncode(query.cacheIdentity)}';
    try {
      final hit = await cache?.read(key);
      if (hit != null) {
        final age = _now().difference(hit.fetchedAt);
        final ttl = hit.candidates.isEmpty ? const Duration(hours: 1) : const Duration(days: 7);
        final normalized = hit.candidates.map((c) => validate(c, query.duration)).whereType<Segment>().toList();
        // Duration buckets share a key, so revalidate against the exact file.
        // A changed boundary must trigger lookup rather than silently lose data.
        if (!age.isNegative && age < ttl && normalized.length == hit.candidates.length) {
          return SegmentResolution(segments: normalized, fromCache: true);
        }
      }
    } on Exception {
      // An unavailable/corrupt cache must not disable skipping or block playback.
    }

    final failures = <String, SegmentFailure>{};
    // null = 还没返回
    final results = List<List<SegmentCandidate>?>.filled(providers.length, null);
    var published = 0;
    void publishDecided() {
      if (onPartial == null) return;
      final (decided, picked) = _select(results, query);
      if (decided <= published || picked.isEmpty) return;
      published = decided;
      onPartial(SegmentResolution(segments: picked.map((c) => validate(c, query.duration)!).toList()));
    }

    await Future.wait([
      for (var i = 0; i < providers.length; i++)
        () async {
          final provider = providers[i];
          var found = <SegmentCandidate>[];
          try {
            found = await provider.fetch(query).timeout(timeout);
          } on TimeoutException {
            failures[provider.id] = SegmentFailure.timeout;
          } on SegmentHttpException catch (e) {
            failures[provider.id] = switch (e.statusCode) {
              401 || 403 => SegmentFailure.unauthorized,
              429 => SegmentFailure.rateLimited,
              _ => SegmentFailure.unavailable,
            };
          } on FormatException {
            failures[provider.id] = SegmentFailure.invalidResponse;
          } on Exception {
            failures[provider.id] = SegmentFailure.unavailable;
          }
          results[i] = found;
          publishDecided();
        }(),
    ]);

    final (_, selected) = _select(results, query);
    selected.sort((a, b) => a.start.compareTo(b.start));
    // Keep raw confidence/null ends in storage to avoid penalizing twice or
    // fixing a null end to the wrong exact duration on the next cache hit.
    if (failures.isEmpty) {
      try {
        await cache?.write(key, SegmentCacheEntry(_now(), selected));
      } on Exception {
        // Persistence is best effort, never part of successful playback.
      }
    }
    return SegmentResolution(segments: selected.map((c) => validate(c, query.duration)!).toList(), failures: failures);
  }

  /// 按类型选出最高优先级来源的片段。某个类型在排在前面的来源都已返回时才算确定；
  /// 返回（已确定的类型数, 已确定类型的片段）
  (int, List<SegmentCandidate>) _select(List<List<SegmentCandidate>?> results, SegmentQuery query) {
    final selected = <SegmentCandidate>[];
    var decided = 0;
    for (final type in SegmentType.values) {
      var settled = true;
      for (var i = 0; i < providers.length; i++) {
        final r = results[i];
        if (r == null) {
          settled = false;
          break;
        }
        final valid = r
            .where((c) => c.type == type && c.provider == providers[i].id && validate(c, query.duration) != null)
            .toList();
        if (valid.isEmpty) continue;
        // Preserve multiple non-overlapping recaps/intros from the winning
        // provider. Prefer confidence when contributor versions overlap.
        valid.sort(
          (a, b) => validate(b, query.duration)!.confidence.compareTo(validate(a, query.duration)!.confidence),
        );
        final kept = <SegmentCandidate>[];
        for (final candidate in valid) {
          final end = candidate.end ?? query.duration;
          if (kept.any((c) => candidate.start < (c.end ?? query.duration) && c.start < end)) {
            continue;
          }
          kept.add(candidate);
        }
        selected.addAll(kept);
        break;
      }
      if (settled) decided++;
    }
    selected.sort((a, b) => a.start.compareTo(b.start));
    return (decided, selected);
  }

  static Segment? validate(SegmentCandidate candidate, Duration duration) {
    final start = candidate.start;
    final end = candidate.end ?? duration;
    if (duration <= Duration.zero || start < Duration.zero || start >= end || end > duration) {
      return null;
    }
    if (candidate.end == null && candidate.type != SegmentType.credits && candidate.type != SegmentType.preview) {
      return null;
    }
    var confidence = candidate.confidence;
    if (!confidence.isFinite || confidence < 0 || confidence > 1) return null;
    final reference = candidate.referenceDuration;
    if (reference != null) {
      if (reference <= Duration.zero) return null;
      if ((reference - duration).abs() > const Duration(seconds: 30)) {
        confidence *= 0.5;
      }
    }
    if (confidence < 0.4) return null;
    switch (candidate.type) {
      case SegmentType.intro:
        final length = end - start;
        if (length < const Duration(seconds: 5) ||
            length > const Duration(seconds: 180) ||
            start.inMilliseconds > duration.inMilliseconds * 0.4) {
          return null;
        }
      case SegmentType.credits:
        if (start.inMilliseconds < duration.inMilliseconds * 0.6 || duration - end > const Duration(minutes: 5)) {
          return null;
        }
      case SegmentType.recap:
      case SegmentType.preview:
        break;
    }
    return Segment(type: candidate.type, start: start, end: end, provider: candidate.provider, confidence: confidence);
  }
}
