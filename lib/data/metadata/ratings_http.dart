import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef RatingJsonFetcher = Future<Object?> Function(Uri uri, Map<String, String> headers);

class RatingsException implements Exception {
  const RatingsException(this.message, {this.retryAfter});
  final String message;
  final Duration? retryAfter;
  @override
  String toString() => message;
}

Uri ratingEndpoint(Uri base, String path, [Map<String, String> query = const {}]) {
  if (base.scheme != 'https' || base.host.isEmpty || base.userInfo.isNotEmpty || base.hasQuery || base.hasFragment) {
    throw const RatingsException('API 地址需要使用 HTTPS，且不带账号密码、参数或片段');
  }
  return base.replace(
    path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}/$path',
    queryParameters: query.isEmpty ? null : query,
  );
}

/// The complete request has an 8-second deadline and a bounded response body.
/// Never follow redirects with credentials, or expose URLs/headers in errors.
Future<Object?> fetchRatingJson(Uri uri, Map<String, String> headers) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  Future<Object?> request() async {
    final req = await client.getUrl(uri);
    req.followRedirects = false;
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    req.headers.set(HttpHeaders.userAgentHeader, 'Viora (external ratings)');
    headers.forEach(req.headers.set);
    final response = await req.close();
    if (response.statusCode == 404 || response.statusCode == 204) return null;
    if (response.statusCode == 429) {
      final raw = response.headers.value('retry-after');
      final seconds = int.tryParse(raw ?? '');
      final date = raw == null ? null : _httpDate(raw);
      final delay = seconds != null
          ? Duration(seconds: seconds.clamp(1, 1800))
          : date == null
          ? const Duration(minutes: 1)
          : Duration(seconds: date.difference(DateTime.now()).inSeconds.clamp(1, 1800));
      throw RatingsException('请求额度已达上限，请稍后重试', retryAfter: delay);
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const RatingsException('访问被拒绝，请检查凭据或网络');
    }
    if (response.statusCode != 200) throw RatingsException('评分服务 HTTP ${response.statusCode}');
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > 1024 * 1024) throw const RatingsException('评分响应过大');
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes));
  }

  try {
    return await request().timeout(const Duration(seconds: 8));
  } on RatingsException {
    rethrow;
  } on FormatException {
    throw const RatingsException('评分服务返回格式错误');
  } on Object {
    throw const RatingsException('评分请求失败，请检查网络或 API 地址');
  } finally {
    client.close(force: true);
  }
}

DateTime? _httpDate(String value) {
  try {
    return HttpDate.parse(value);
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> ratingObject(Object? value) {
  if (value is! Map<String, dynamic>) throw const RatingsException('评分服务返回格式错误');
  return value;
}

double? ratingNumber(Object? value, double scale) {
  final number = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value)
      : null;
  return number != null && number.isFinite && number >= 0 && number <= scale ? number : null;
}

int? ratingVotes(Object? value) {
  if (value is int) return value >= 0 ? value : null;
  if (value is! String || !RegExp(r'^(?:\d+|\d{1,3}(?:,\d{3})+)$').hasMatch(value)) return null;
  return int.tryParse(value.replaceAll(',', ''));
}
