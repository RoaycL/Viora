// 连接真实服务器的联调测试（默认跳过）：
//   VIORA_LIVE=1 flutter test test/live/jellyfin_demo_test.dart
// 使用 Jellyfin 官方公开演示服（用户 demo，空密码）。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/index/media_index.dart';
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

  test('Jellyfin 演示服：同步索引（分页 + 增量参数）并搜索', () async {
    var server = const ServerConfig(
      id: 'demo',
      type: ServerType.jellyfin,
      name: 'Jellyfin Demo',
      username: 'demo',
      lines: [ServerLine(id: 'ok', name: '主线路', url: 'https://demo.jellyfin.org/stable')],
    );
    final client = EmbyClient(
      config: const AppConfig(deviceId: 'viora-test'),
      server: server,
      appVersion: '0.4.0',
      onServerChanged: (s) => server = s,
    );
    final index = (await MediaIndex.open(path: ':memory:'))!;
    final gen = index.beginFull('demo');
    var start = 0;
    while (true) {
      final page = await client.items(start: start, limit: 50, sortBy: 'DateCreated,SortName', sortOrder: 'Ascending');
      index.upsert('demo', page.items, gen: gen);
      start += page.items.length;
      if (page.items.isEmpty || start >= page.total) break;
    }
    index.finishFull('demo', gen);
    expect(index.count('demo'), greaterThan(5));

    // 增量：只取最近修改过的（参数被服务器接受即可）
    final incr = await client.items(limit: 10, minDateLastSaved: DateTime.now().subtract(const Duration(days: 3650)));
    expect(incr.total, greaterThanOrEqualTo(0));

    final hits = index.search('sahara');
    expect(hits, isNotEmpty);
    expect(index.matches(hits.first).first.id, hits.first.id);
    index.close();
  }, skip: live ? false : '需要 VIORA_LIVE=1');
}
