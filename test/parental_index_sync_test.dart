import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/emby/emby_client.dart';

// 不能用 TestWidgetsFlutterBinding：它会让所有 HttpClient 请求返回 400
void main() {
  ServerConfig server(String url) => ServerConfig(
    id: 's',
    type: ServerType.emby,
    name: 'home',
    username: 'alice',
    userId: 'u1',
    token: 'tok',
    lines: [ServerLine(id: 'l', name: 'main', url: url)],
  );

  test('儿童模式下同步索引：不按儿童模式过滤，片库完整写进索引', () async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => http.close(force: true));
    final queries = <Map<String, String>>[];
    http.listen((request) async {
      queries.add(request.uri.queryParameters);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'Items': [
            {'Id': 'a', 'Type': 'Movie', 'Name': '动画', 'OfficialRating': 'G'},
            {'Id': 'b', 'Type': 'Movie', 'Name': '成人片', 'OfficialRating': 'R'},
          ],
          'TotalRecordCount': 2,
        }),
      );
      await request.response.close();
    });
    final s = server('http://127.0.0.1:${http.port}');
    final client = EmbyClient(
      config: AppConfig(servers: [s], parental: const ParentalConfig(enabled: true, maxAge: 7)),
      server: s,
      appVersion: 't',
    );
    final kids = await client.items(limit: 10);
    expect(kids.items.map((e) => e.id), ['a']);
    expect(queries.last['MaxOfficialRating'], isNotNull);

    final all = await EmbyClient.unfilteredByParental(() => client.items(limit: 10));
    expect(all.items.map((e) => e.id), ['a', 'b']);
    expect(queries.last.containsKey('MaxOfficialRating'), isFalse);

    // 之后的普通请求照常过滤
    expect((await client.items(limit: 10)).items.map((e) => e.id), ['a']);
  });
}
