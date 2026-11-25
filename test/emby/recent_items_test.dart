import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/emby/emby_client.dart';

/// 本机假服务器：所有请求都返回 [body]，记下路径
Future<(HttpServer, List<String>)> _serve(Object Function(Uri uri) body) async {
  final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final paths = <String>[];
  http.listen((request) async {
    final uri = request.uri.replace(path: request.uri.path.replaceFirst(RegExp('^/emby'), ''));
    paths.add('${request.method} ${uri.path}');
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body(uri)));
    await request.response.close();
  });
  return (http, paths);
}

EmbyClient _client(String url, {String userId = 'u1'}) {
  final server = ServerConfig(
    id: 's',
    type: ServerType.emby,
    name: 'home',
    username: 'alice',
    userId: userId,
    token: 'token',
    lines: [ServerLine(id: 'l', name: 'main', url: url)],
  );
  return EmbyClient(
    config: AppConfig(servers: [server]),
    server: server,
    appVersion: 'test',
  );
}

void main() {
  setUp(EmbyClient.clearRecentItems);

  test('单条详情取过后，起播直接用缓存；标记已看后清掉', () async {
    final (http, paths) = await _serve((_) => {'Id': 'x1', 'Type': 'Movie', 'Name': 'a'});
    addTearDown(() => http.close(force: true));
    final c = _client('http://127.0.0.1:${http.port}');
    expect(c.recentItem('x1'), isNull);
    await c.item('x1');
    expect(c.recentItem('x1')?.name, 'a');
    expect(c.recentItem('x1', maxAge: Duration.zero), isNull);
    await c.setPlayed('x1', true);
    expect(c.recentItem('x1'), isNull);
  });

  test('继续观看列表里的条目也会记下；换账号不共用', () async {
    final (http, _) = await _serve(
      (_) => {
        'Items': [
          {'Id': 'e1', 'Type': 'Episode', 'Name': '第 1 集'},
        ],
        'TotalRecordCount': 1,
      },
    );
    addTearDown(() => http.close(force: true));
    final url = 'http://127.0.0.1:${http.port}';
    await _client(url).resume();
    expect(_client(url).recentItem('e1')?.name, '第 1 集');
    expect(_client(url, userId: 'u2').recentItem('e1'), isNull);
    _client(url).forgetItem('e1');
    expect(_client(url).recentItem('e1'), isNull);
  });
}
