import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/segments/segment_http.dart';

void main() {
  test('API base URLs preserve reverse-proxy path and reject unsafe formats', () {
    final uri = segmentEndpoint(Uri.parse('https://proxy.example/segments/v3/'), 'media', {'tmdb_id': '1396'});
    expect(uri.toString(), 'https://proxy.example/segments/v3/media?tmdb_id=1396');
    for (final base in [
      'http://api.example',
      'https://key@api.example',
      'https://api.example?q=key',
      'https://api.example#fragment',
      '/relative',
    ]) {
      expect(() => segmentEndpoint(Uri.parse(base), 'media', {}), throwsFormatException);
    }
  });

  test('404 is missing data; redirects never receive credentials', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = Uri.parse('http://127.0.0.1:${server.port}');
    var redirected = false;
    server.listen((request) async {
      if (request.uri.path == '/redirect') {
        request.response.statusCode = 302;
        request.response.headers.set('location', '$origin/key-target');
      } else if (request.uri.path == '/key-target') {
        redirected = true;
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    try {
      expect(await fetchSegmentJson(origin.resolve('/missing'), {}), isNull);
      await expectLater(
        fetchSegmentJson(origin.resolve('/redirect'), {'Authorization': 'Bearer user-key'}),
        throwsA(isA<SegmentHttpException>().having((e) => e.statusCode, 'status', 302)),
      );
      expect(redirected, isFalse);
    } finally {
      await server.close(force: true);
    }
  });

  test('body stall is covered by the three-second timeout', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{');
      await request.response.flush();
      // Intentionally leave the body open; client must cancel it.
    });
    try {
      await expectLater(
        fetchSegmentJson(Uri.parse('http://127.0.0.1:${server.port}/stall'), {}),
        throwsA(isA<TimeoutException>()),
      );
    } finally {
      await server.close(force: true);
    }
  });
}
