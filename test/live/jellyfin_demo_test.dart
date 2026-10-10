// 连接真实服务器的联调测试（默认跳过）：
//   VIORA_LIVE=1 flutter test test/live/jellyfin_demo_test.dart
// 使用 Jellyfin 官方公开演示服（用户 demo，空密码）。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/media/media_models.dart';

void main() {
  final live = Platform.environment['VIORA_LIVE'] == '1';

  test('Jellyfin 演示服：登录、浏览、播放信息、直链', () async {
    var server = const ServerConfig(
      id: 'demo',
      type: ServerType.jellyfin,
      name: 'Jellyfin Demo',
      username: 'demo',
      lines: [
        ServerLine(id: 'bad', name: '坏线路', url: 'https://127.0.0.1:1'),
        ServerLine(id: 'ok', name: '主线路', url: 'https://demo.jellyfin.org/stable'),
      ],
    );
    final client = EmbyClient(
      config: const AppConfig(deviceId: 'viora-test'),
      server: server,
      appVersion: '0.2.0',
      onServerChanged: (s) => server = s,
    );

    final probed = await client.probeAll();
    expect(probed.lines.firstWhere((l) => l.id == 'bad').latencyMs, isNull);
    expect(probed.lines.firstWhere((l) => l.id == 'ok').latencyMs, isNotNull);
    expect(client.line.id, 'ok');

    await client.login();
    expect(server.token, isNotNull);

    final libs = await client.libraries();
    expect(libs, isNotEmpty);
    final movies = libs.firstWhere((l) => l.collectionType == 'movies', orElse: () => libs.first);

    final page = await client.items(parentId: movies.id, limit: 5);
    expect(page.items, isNotEmpty);
    final movie = page.items.firstWhere((i) => i.kind == MediaKind.movie, orElse: () => page.items.first);

    final info = await client.playbackInfo(movie.id);
    expect(info.sources, isNotEmpty);
    final req = client.stream(info.sources.first, playSessionId: info.playSessionId);
    expect(req.headers['User-Agent'], startsWith('Viora/'));

    final r = await Dio().getUri<dynamic>(
      req.url,
      options: Options(
        headers: {...req.headers, 'Range': 'bytes=0-1023'},
        responseType: ResponseType.bytes,
        validateStatus: (_) => true,
      ),
    );
    expect(r.statusCode, anyOf(200, 206));

    final img = client.image(movie.primary!);
    final ir = await Dio().getUri<dynamic>(
      img.url,
      options: Options(headers: img.headers, responseType: ResponseType.bytes, validateStatus: (_) => true),
    );
    expect(ir.statusCode, 200);
  }, skip: live ? false : '需要 VIORA_LIVE=1');
}
