import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 请求头里的应用版本（启动时设置）
String segmentClientVersion = '0';

typedef SegmentJsonFetcher = Future<Object?> Function(Uri uri, Map<String, String> headers);

/// The timeout covers DNS, connection, headers AND body. No automatic retries:
/// all providers share the resolver's 6-second budget (playback never waits for it).
Future<Object?> fetchSegmentJson(Uri uri, Map<String, String> headers) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  Future<Object?> request() async {
    final req = await client.getUrl(uri);
    req.followRedirects = false; // Never forward an end-user key to a redirected host.
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    req.headers.set(HttpHeaders.userAgentHeader, 'Viora/$segmentClientVersion (segments)');
    headers.forEach(req.headers.set);
    final response = await req.close();
    if (response.statusCode == 404 || response.statusCode == 204) return null;
    if (response.statusCode != 200) {
      throw SegmentHttpException(response.statusCode);
    }
    const maxBytes = 1024 * 1024;
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const FormatException('Segment response too large');
      }
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes));
  }

  try {
    return await request().timeout(const Duration(seconds: 6));
  } finally {
    client.close(force: true);
  }
}

class SegmentHttpException implements Exception {
  const SegmentHttpException(this.statusCode);
  final int statusCode;
  @override
  String toString() => 'Segment API HTTP $statusCode';
}

Uri segmentEndpoint(Uri baseUrl, String path, Map<String, String> query) {
  if (baseUrl.scheme != 'https' ||
      baseUrl.host.isEmpty ||
      baseUrl.userInfo.isNotEmpty ||
      baseUrl.hasQuery ||
      baseUrl.hasFragment) {
    throw const FormatException('API base URL must be an HTTPS URL without credentials, query or fragment');
  }
  return baseUrl.replace(path: '${baseUrl.path.replaceFirst(RegExp(r'/+$'), '')}/$path', queryParameters: query);
}

Map<String, dynamic> segmentObject(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected segment object');
  }
  return value;
}

Duration? segmentMilliseconds(Object? value) {
  if (value is! num || !value.isFinite) return null;
  return Duration(milliseconds: value.round());
}

Duration? segmentSeconds(Object? value) {
  if (value is num && value.isFinite) {
    return Duration(milliseconds: (value * 1000).round());
  }
  // IntroDB accepts both seconds and clock-style timestamps.
  if (value is String) {
    final parts = value.split(':');
    if (parts.length > 3 || parts.isEmpty) return null;
    double seconds = 0;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      final number = double.tryParse(part);
      if (number == null || !number.isFinite || number < 0) return null;
      if (i > 0 && number >= 60) return null;
      if (i < parts.length - 1 && number != number.truncateToDouble()) {
        return null;
      }
      seconds = seconds * 60 + number;
    }
    return Duration(milliseconds: (seconds * 1000).round());
  }
  return null;
}

/// Reject an explicitly mismatched identifier; do not guess an episode from a
/// title or silently apply a neighbouring episode's timestamps.
void verifySegmentIdentity(Map<String, dynamic> response, Map<String, Object?> expected) {
  for (final entry in expected.entries) {
    final actual = response[entry.key];
    if (actual != null && entry.value != null && actual.toString() != entry.value.toString()) {
      throw const FormatException('Segment response identifies a different media item');
    }
  }
}

double segmentConfidence(Map<String, dynamic> row) {
  final value = row['confidence'];
  if (value == null) return 1;
  return value is num && value.isFinite ? value.toDouble() : 0;
}
