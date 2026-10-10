// 片头片尾数据源联调（默认跳过）：VIORA_LIVE=1 flutter test test/live/segments_live_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/net/request_composer.dart';
import 'package:viora/data/segments/introdb_provider.dart';
import 'package:viora/data/segments/server_provider.dart';
import 'package:viora/data/segments/theintrodb_provider.dart';
import 'package:viora/domain/models/segment.dart';
import 'package:viora/domain/usecases/segment_resolver.dart';

void main() {
  final live = Platform.environment['VIORA_LIVE'] == '1';
  final proxy = Platform.environment['VIORA_PROXY'] ?? 'https://embyproxy.roayc.com/proxy/';

  // 绝命毒师 S01E01（TMDB 1396 / IMDb tt0903747）
  const query = SegmentQuery(
    titleKey: 'breaking-bad',
    kind: SegmentMediaKind.episode,
    duration: Duration(milliseconds: 3500000),
    tmdbId: 1396,
    imdbId: 'tt0903747',
    season: 1,
    episode: 1,
  );

  for (final viaProxy in [false, true]) {
    test('TheIntroDB + IntroDB 真实接口${viaProxy ? '（经反向代理）' : ''}', () async {
      Uri base(String url) => viaProxy ? proxify(Uri.parse(url), proxy) : Uri.parse(url);
      final resolver = SegmentResolver(
        providers: [
          TheIntroDbProvider(baseUrl: base('https://api.theintrodb.org/v3')),
          IntroDbProvider(baseUrl: base('https://api.introdb.app')),
        ],
        timeout: const Duration(seconds: 10),
      );
      final r = await resolver.resolve(query);
      // ignore: avoid_print
      print([for (final s in r.segments) '${s.type.name} ${s.start}–${s.end} ${s.provider}'].join('\n'));
      expect(r.failures, isEmpty);
      expect(r.segments.any((s) => s.type == SegmentType.intro), isTrue);
      expect(r.segments.any((s) => s.type == SegmentType.credits), isTrue);
    }, skip: live ? false : '需要 VIORA_LIVE=1');
  }

  test('Jellyfin 演示服：媒体片段 / 章节接口可用', () async {
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
      appVersion: '0.8.0',
      onServerChanged: (s) => server = s,
    );
    final page = await client.items(types: 'Movie,Episode', limit: 3);
    expect(page.items, isNotEmpty);
    final item = page.items.first;
    final source = ServerSegmentSource(client, item.id);
    final segments = await ServerSegmentProvider(source).fetch(
      SegmentQuery(titleKey: item.id, kind: SegmentMediaKind.movie, duration: item.runtime ?? const Duration(hours: 1)),
    );
    final chapters = await source.chapters();
    // ignore: avoid_print
    print('${item.name}: ${segments.length} 个服务器片段，${chapters.length} 个章节');
  }, skip: live ? false : '需要 VIORA_LIVE=1');
}
