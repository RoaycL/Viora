import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/metadata/ratings_http.dart';

void main() {
  test('HTTP errors redact URL/key and do not follow credential-bearing redirects', () async {
    var targetHits = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final response = req.response;
      if (req.uri.path == '/redirect') {
        response.statusCode = 302;
        response.headers.set('location', '/target');
      } else if (req.uri.path == '/target') {
        targetHits++;
        response.write('{}');
      } else {
        response.statusCode = 401;
        response.write('private-key');
      }
      await response.close();
    });
    for (final path in ['redirect', 'auth']) {
      final uri = Uri.parse('http://127.0.0.1:${server.port}/$path?apikey=private-key');
      await expectLater(
        fetchRatingJson(uri, {'trakt-api-key': 'private-key'}),
        throwsA(
          isA<RatingsException>().having((e) => e.toString(), 'redacted message', isNot(contains('private-key'))),
        ),
      );
    }
    expect(targetHits, 0);
  });

  test('HTTP 404 is absence; 429 preserves Retry-After; invalid/oversized JSON fails', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final response = req.response;
      switch (req.uri.path) {
        case '/missing':
          response.statusCode = 404;
        case '/limited':
          response.statusCode = 429;
          response.headers.set('retry-after', '120');
        case '/invalid':
          response.write('not JSON');
        case '/large':
          response.write('x' * (1024 * 1024 + 1));
      }
      try {
        await response.close();
      } catch (_) {
        /* Reader may cancel at the size limit. */
      }
    });
    Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}/$path');
    expect(await fetchRatingJson(url('missing'), {}), isNull);
    await expectLater(
      fetchRatingJson(url('limited'), {}),
      throwsA(isA<RatingsException>().having((e) => e.retryAfter, 'backoff', const Duration(seconds: 120))),
    );
    for (final path in ['invalid', 'large']) {
      await expectLater(fetchRatingJson(url(path), {}), throwsA(isA<RatingsException>()));
    }
  });
}
