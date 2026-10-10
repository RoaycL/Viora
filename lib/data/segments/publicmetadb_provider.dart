import '../../domain/models/segment.dart';
import 'segment_http.dart';
import 'segment_provider.dart';

/// PublicMetaDB skip submissions. Its documented skip fields have no recap.
class PublicMetaDbProvider implements SegmentProvider {
  PublicMetaDbProvider({required this.apiKey, Uri? baseUrl, SegmentJsonFetcher? fetcher})
    : baseUrl = baseUrl ?? Uri.parse('https://publicmetadb.com'),
      _fetcher = fetcher ?? fetchSegmentJson;

  final String apiKey;
  final Uri baseUrl;
  final SegmentJsonFetcher _fetcher;
  @override
  String get id => 'publicmetadb';

  @override
  Future<List<SegmentCandidate>> fetch(SegmentQuery query) async {
    if (!query.canLookup || query.tmdbId == null || query.tmdbId! <= 0 || apiKey.isEmpty) {
      return [];
    }
    final params = <String, String>{
      'tmdb_id': '${query.tmdbId}',
      'media_type': query.kind == SegmentMediaKind.movie ? 'movie' : 'tv',
      if (query.kind == SegmentMediaKind.episode) 'season': '${query.season}',
      if (query.kind == SegmentMediaKind.episode) 'episode': '${query.episode}',
    };
    final body = await _fetcher(segmentEndpoint(baseUrl, 'api/external/skips', params), {
      'Authorization': 'Bearer $apiKey',
    });
    if (body == null) return [];
    final json = segmentObject(body);
    verifySegmentIdentity(json, {
      'tmdb_id': query.tmdbId,
      'media_type': query.kind == SegmentMediaKind.movie ? 'movie' : 'tv',
      if (query.kind == SegmentMediaKind.episode) 'season': query.season,
      if (query.kind == SegmentMediaKind.episode) 'episode': query.episode,
    });
    // /skips returns contributor rows under items; the homepage also shows a
    // flattened example. Accept both, with the same millisecond semantics.
    final Object? entries = json.containsKey('items') ? json['items'] : [json];
    if (entries == null) return [];
    if (entries is! List) {
      throw const FormatException('Expected PublicMetaDB items');
    }
    final out = <SegmentCandidate>[];
    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) continue;
      for (final type in [SegmentType.intro, SegmentType.credits]) {
        final start = segmentMilliseconds(entry['${type.name}_start_ms']);
        final rawEnd = entry['${type.name}_end_ms'];
        final end = segmentMilliseconds(rawEnd);
        if (start == null || (rawEnd != null && end == null)) continue;
        if (type == SegmentType.intro && end == null) continue;
        out.add(
          SegmentCandidate(
            type: type,
            start: start,
            end: end,
            provider: id,
            confidence: segmentConfidence(entry),
            referenceDuration: segmentMilliseconds(entry['duration_ms']),
          ),
        );
      }
    }
    return out;
  }
}
