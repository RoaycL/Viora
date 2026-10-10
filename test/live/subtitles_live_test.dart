// 在线字幕联调（默认跳过）：VIORA_LIVE=1 flutter test test/live/subtitles_live_test.dart
// Jellyfin 演示服：demo 账号通常没有字幕管理权限，期望得到明确的 401/403 而不是解析错误；有权限时返回列表。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/media/media_models.dart';

void main() {
  final live = Platform.environment['VIORA_LIVE'] == '1';

  test(
    'Jellyfin 演示服：在线搜索字幕接口',
    () async {
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
        appVersion: '0.13.0',
        onServerChanged: (s) => server = s,
      );
      await client.login();
      final libs = await client.libraries();
      final movies = libs.firstWhere((l) => l.collectionType == 'movies', orElse: () => libs.first);
      final movie = (await client.items(
        parentId: movies.id,
        limit: 5,
      )).items.firstWhere((i) => i.kind == MediaKind.movie);
      try {
        final list = await client.searchSubtitles(movie.id, 'eng');
        // ignore: avoid_print
        print('「${movie.name}」英文字幕：${list.length} 个 ${list.take(3).map((r) => '${r.name}/${r.provider}').join(' | ')}');
      } on MediaServerException catch (e) {
        // ignore: avoid_print
        print('「${movie.name}」搜索字幕：${e.statusCode} ${e.message}');
        expect(e.statusCode, anyOf(401, 403, 404, 500));
      }
    },
    skip: !live,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
