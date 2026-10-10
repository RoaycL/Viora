// 弹幕服务器联调（默认跳过）：
// VIORA_LIVE=1 VIORA_DANMU=http://127.0.0.1:9321/87654321 flutter test test/live/danmaku_live_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/danmaku/danmaku_client.dart';
import 'package:viora/features/danmaku/danmaku_service.dart';

void main() {
  final live = Platform.environment['VIORA_LIVE'] == '1';
  final server = Platform.environment['VIORA_DANMU'] ?? 'http://127.0.0.1:9321/87654321';
  final client = DanmakuClient(DanmakuConfig(servers: [server], maxCount: 3000, searchBlockWords: '解说,手语'));

  test(
    '连接测试：正确地址通过，错误 token 报错',
    () async {
      await DanmakuClient.test(server);
      final bad = Uri.parse(server).replace(path: '/wrong-token').toString();
      await expectLater(DanmakuClient.test(bad), throwsA(isA<DanmakuException>()));
    },
    skip: !live,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    '搜索 → 选集 → 弹幕',
    () async {
      final animes = await client.search('凡人修仙传', season: 1);
      expect(animes, isNotEmpty);
      expect(animes.any((a) => a.title.contains('解说')), isFalse);
      // ignore: avoid_print
      print('搜索：${animes.take(5).map((a) => a.title).join(' | ')}');
      final eps = await client.episodes(animes.first);
      expect(eps, isNotEmpty);
      final track = await client.load(eps.first.server, eps.first.episodeId, source: 'test');
      // ignore: avoid_print
      print(
        '弹幕：${track.comments.length} 条，前 3 条：${track.comments.take(3).map((c) => '${c.time}s ${c.text}').join(' / ')}',
      );
      expect(track.comments.length, inInclusiveRange(1, 3000));
    },
    skip: !live,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    '自动匹配：剧名 + 季 + 集',
    () async {
      const target = DanmakuTarget(title: '凡人修仙传', key: 'k', season: 1, episode: 2);
      final track = await resolveDanmaku(client, target);
      expect(track, isNotNull);
      // ignore: avoid_print
      print('匹配：${track!.source} · ${track.comments.length} 条');
      expect(track.source, contains('2'));
      expect(track.comments, isNotEmpty);
    },
    skip: !live,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
