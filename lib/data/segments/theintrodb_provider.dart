import '../../domain/models/segment.dart';
import 'segment_http.dart';
import 'segment_provider.dart';

/// TheIntroDB v4 /media（https://theintrodb.org/openapi.yaml）：各片段类型是毫秒数组。
/// v4 的响应以 tvdb_id 为身份、不再带 tmdb_id；按 tmdb_id / imdb_id 查询由服务端换算，季集号按 TMDB 编号。
/// details=true 时每段带 confidence，整体带 group_duration_ms（所选版本的代表时长）。
class TheIntroDbProvider implements SegmentProvider {
  TheIntroDbProvider({Uri? baseUrl, this.apiKey, SegmentJsonFetcher? fetcher})
    : baseUrl = baseUrl ?? Uri.parse('https://api.theintrodb.org/v4'),
      _fetcher = fetcher ?? fetchSegmentJson;

  final Uri baseUrl;
  final String? apiKey;
  final SegmentJsonFetcher _fetcher;
  @override
  String get id => 'theintrodb';

  @override
  Future<List<SegmentCandidate>> fetch(SegmentQuery query) async {
    if (!query.canLookup) return [];
    final params = <String, String>{};
    if (query.tmdbId != null && query.tmdbId! > 0) {
      params['tmdb_id'] = '${query.tmdbId}';
    } else if (query.imdbId != null && RegExp(r'^tt\d+$').hasMatch(query.imdbId!)) {
      params['imdb_id'] = query.imdbId!;
    } else {
      return [];
    }
    if (query.kind == SegmentMediaKind.episode) {
      params['season'] = '${query.season}';
      params['episode'] = '${query.episode}';
    }
    params['duration_ms'] = '${query.duration.inMilliseconds}';
    params['details'] = 'true';
    final body = await _fetcher(segmentEndpoint(baseUrl, 'media', params), {
      if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    });
    if (body == null) return [];
    final json = segmentObject(body);
    verifySegmentIdentity(json, {
      'tmdb_id': params.containsKey('tmdb_id') ? query.tmdbId : null,
      'type': query.kind == SegmentMediaKind.movie ? 'movie' : 'tv',
      if (query.kind == SegmentMediaKind.episode) 'season': query.season,
      if (query.kind == SegmentMediaKind.episode) 'episode': query.episode,
    });
    final out = <SegmentCandidate>[];
    for (final type in SegmentType.values) {
      final entries = json[type.name];
      if (entries == null) continue;
      if (entries is! List) {
        throw const FormatException('Expected TheIntroDB segment array');
      }
      for (final entry in entries) {
        if (entry is! Map<String, dynamic> || !entry.containsKey('start_ms') || !entry.containsKey('end_ms')) {
          continue;
        }
        final start = entry['start_ms'] == null ? Duration.zero : segmentMilliseconds(entry['start_ms']);
        final end = segmentMilliseconds(entry['end_ms']);
        if (start == null || (entry['end_ms'] != null && end == null)) continue;
        if (end == null && type != SegmentType.credits && type != SegmentType.preview) {
          continue;
        }
        out.add(
          SegmentCandidate(
            type: type,
            start: start,
            end: end,
            provider: id,
            confidence: segmentConfidence(entry),
            referenceDuration: segmentMilliseconds(
              entry['video_duration_ms'] ?? json['group_duration_ms'] ?? json['video_duration_ms'],
            ),
          ),
        );
      }
    }
    return out;
  }
}
