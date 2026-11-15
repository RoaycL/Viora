import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/media/server_registry.dart';

void main() {
  late ServerSocket fake;
  var connections = 0;

  /// [failFirst] 个连接收到请求后直接断开（复用的空闲连接被服务器关掉时就是这样），之后正常回应
  Future<EmbyClient> start(int failFirst) async {
    connections = 0;
    fake = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    fake.listen((socket) {
      final n = ++connections;
      socket.listen((_) {
        if (n <= failFirst) {
          socket.destroy();
          return;
        }
        final body = jsonEncode({'ServerName': 'ok'});
        socket.write(
          'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n'
          'Content-Length: ${utf8.encode(body).length}\r\nConnection: close\r\n\r\n$body',
        );
        socket.close();
      }, onError: (_) {});
    });
    return clientForDraft(
      const AppConfig(deviceId: 'dev'),
      ServerConfig(
        id: 's',
        type: ServerType.emby,
        name: 't',
        username: 'me',
        lines: [ServerLine(id: 'l', name: 'l', url: 'http://127.0.0.1:${fake.port}')],
      ),
    );
  }

  tearDown(() => fake.close());

  test('连接在收到回应前被断开：GET 用新连接重试一次，成功', () async {
    final client = await start(1);
    expect((await client.publicInfo())['ServerName'], 'ok');
    expect(connections, 2);
  });

  test('一直断开：只重试一次，然后报错（不会无限重试）', () async {
    final client = await start(99);
    await expectLater(client.publicInfo(), throwsA(isA<MediaServerException>()));
    expect(connections, 2);
  });
}
