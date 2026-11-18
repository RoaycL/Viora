import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/media/media_models.dart';
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

  test('播放停止上报（POST）遇到断开的连接也重试一次：进度不会因为没报上去而丢', () async {
    final draft = await start(1);
    final client = clientForDraft(const AppConfig(deviceId: 'dev'), draft.server.copyWith(token: 'tok', userId: 'uid'));
    await client.reportStopped(
      const MediaSourceInfo(serverId: 's', itemId: 'ep', id: 'src', container: 'mkv'),
      const Duration(minutes: 41),
      'session',
    );
    expect(connections, 2, reason: '第一次连接被断开后用新连接重发了');
  });

  test('应用内更新重启前等还没发完的播放上报（最多等 5 秒）', () async {
    final slow = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(slow.close);
    var received = false;
    slow.listen((socket) {
      socket.listen((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        received = true;
        socket.write('HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n');
        await socket.close();
      }, onError: (_) {});
    });
    final client = clientForDraft(
      const AppConfig(deviceId: 'dev'),
      ServerConfig(
        id: 's',
        type: ServerType.emby,
        name: 't',
        username: 'me',
        token: 'tok',
        userId: 'uid',
        lines: [ServerLine(id: 'l', name: 'l', url: 'http://127.0.0.1:${slow.port}')],
      ),
    );
    // 播放器关闭时发出停止上报，不等它
    unawaited(
      client.reportStopped(
        const MediaSourceInfo(serverId: 's', itemId: 'ep', id: 'src', container: 'mkv'),
        const Duration(minutes: 41),
        'session',
      ),
    );
    await EmbyClient.flushReports();
    expect(received, isTrue);
  });
}
