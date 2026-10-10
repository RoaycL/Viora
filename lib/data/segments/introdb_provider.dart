import '../../domain/models/segment.dart';
import 'segment_http.dart';
import 'segment_provider.dart';

/// IntroDB /segments (not the legacy intro-only /intro endpoint).
class IntroDbProvider implements SegmentProvider {
  IntroDbProvider({Uri? baseUrl, this.apiKey, SegmentJsonFetcher? fetcher})
    : baseUrl = baseUrl ?? Uri.parse('https://api.introdb.app'),
      _fetcher = fetcher ?? fetchSegmentJson;

  final Uri baseUrl;
  final String? apiKey;
  final SegmentJsonFetcher _fetcher;
  @override
  String get id => 'introdb';

  @override
  Future<List<SegmentCandidate>> fetch(SegmentQuery query) async {
    if (!query.canLookup || query.imdbId == null || !RegExp(r'^tt\d+$').hasMatch(query.imdbId!)) {
      return [];
    }
    final params = <String, String>{'imdb_id': query.imdbId!};
    if (query.kind == SegmentMediaKind.movie) {
      params['is_movie'] = 'true';
    } else {
      params['season'] = '${query.season}';
      params['episode'] = '${query.episode}';
    }
    final body = await _fetcher(segmentEndpoint(baseUrl, 'segments', params), {
      if (apiKey != null && apiKey!.isNotEmpty) 'X-API-Key': apiKey!,
    });
    if (body == null) return [];
    final json = segmentObject(body);
    verifySegmentIdentity(json, {
      'imdb_id': query.imdbId,
      if (query.kind == SegmentMediaKind.episode) 'season': query.season,
      if (query.kind == SegmentMediaKind.episode) 'episode': query.episode,
    });
    final out = <SegmentCandidate>[];
    for (final mapping in {
      'intro': SegmentType.intro,
      'recap': SegmentType.recap,
      'outro': SegmentType.credits,
    }.entries) {
      final entry = json[mapping.key];
      if (entry == null) continue;
      final row = segmentObject(entry);
      final start = _time(row, 'start');
      var end = _time(row, 'end');
      if (start == null || end == null) continue;
      // A post-credit scene is content, never a preview or a "next episode" marker.
      final stinger = json['post_credits'];
      if (mapping.value == SegmentType.credits && stinger is Map<String, dynamic>) {
        final stingerStart = _time(stinger, 'start');
        if (stingerStart != null && stingerStart > start && stingerStart < end) {
          end = stingerStart;
        }
      }
      out.add(
        SegmentCandidate(
          type: mapping.value,
          start: start,
          end: end,
          provider: id,
          confidence: segmentConfidence(row),
          referenceDuration: segmentMilliseconds(row['duration_ms'] ?? json['duration_ms']),
        ),
      );
    }
    return out;
  }

  Duration? _time(Map<String, dynamic> row, String field) =>
      row.containsKey('${field}_ms') ? segmentMilliseconds(row['${field}_ms']) : segmentSeconds(row['${field}_sec']);
}
