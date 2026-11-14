import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/tmdb/tmdb_client.dart';

void main() {
  test('TMDB 请求有并发上限：一次来几十个也只同时发出 maxRequests 个，其余排队，全部完成', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var active = 0, peak = 0, served = 0;
    server.listen((req) async {
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'title': req.uri.path}));
      await req.response.close();
      active--;
      served++;
    });
    final saved = TmdbClient.maxRequests;
    TmdbClient.maxRequests = 3;
    addTearDown(() => TmdbClient.maxRequests = saved);
    final client = TmdbClient(
      TmdbConfig(apiKey: 'test', baseUrl: 'http://${server.address.host}:${server.port}'),
      const ProxyConfig(),
    );
    final results = await Future.wait([for (var i = 0; i < 20; i++) client.get('/movie/$i')]);
    expect(results.map((r) => r['title']), [for (var i = 0; i < 20; i++) '/movie/$i']);
    expect(served, 20);
    expect(peak, lessThanOrEqualTo(3));
    expect(TmdbClient.activeRequests, 0);
  });
}
