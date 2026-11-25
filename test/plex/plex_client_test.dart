import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/media/media_models.dart';

/// 本机假 Plex 服务器：按路径返回 JSON，记下收到的请求
class _Fake {
  _Fake(this.http);
  final HttpServer http;
  final requests = <Uri>[];
  final headers = <HttpHeaders>[];
  Object Function(Uri uri) body = (_) => const {'MediaContainer': {}};

  static Future<_Fake> start() async {
    final f = _Fake(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    f.http.listen((request) async {
      f.requests.add(request.uri);
      f.headers.add(request.headers);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(f.body(request.uri)));
      await request.response.close();
    });
    return f;
  }

  String get url => 'http://127.0.0.1:${http.port}';
}

Map<String, dynamic> _mc(Map<String, dynamic> m) => {'MediaContainer': m};

const _sections = {
  'Directory': [
    {'key': '1', 'title': '电影', 'type': 'movie'},
    {'key': '2', 'title': '剧集', 'type': 'show'},
    {'key': '3', 'title': '音乐', 'type': 'artist'},
  ],
};

EmbyClient _client(_Fake fake) {
  final server = ServerConfig(
    id: 'p',
    type: ServerType.plex,
    name: 'plex',
    username: '',
    password: 'account-token',
    userId: 'token-abc',
    token: 'server-token',
    lines: [ServerLine(id: 'l', name: 'main', url: fake.url)],
  );
  return mediaServerClient(
    config: AppConfig(servers: [server]),
    server: server,
    appVersion: 'test',
  );
}

void main() {
  test('按类型创建 Plex 客户端，请求带 Plex 身份和令牌、要 JSON', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.body = (_) => _mc(_sections);
    final client = _client(fake);
    expect(client, isA<PlexClient>());
    final libs = await client.libraries();
    expect(libs.map((l) => (l.id, l.collectionType)), [('1', 'movies'), ('2', 'tvshows')]);
    final h = fake.headers.single;
    expect(h.value('X-Plex-Token'), 'server-token');
    expect(h.value('Accept'), 'application/json');
    expect(h.value('X-Plex-Client-Identifier'), endsWith('-plex'));
    expect(h.value('X-Plex-Product'), 'Viora');
  });

  test('解析条目：Guid、季名、图片路径、观看进度', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.body = (uri) => switch (uri.path) {
      '/library/sections' => _mc(_sections),
      '/library/sections/2/all' => _mc({
        'totalSize': 1,
        'Metadata': [
          {
            'ratingKey': '100',
            'type': 'show',
            'title': '蚝油的鲜味传奇',
            'year': 2026,
            'contentRating': 'TV-14',
            'audienceRating': 8.4,
            'thumb': '/library/metadata/100/thumb/1700',
            'art': '/library/metadata/100/art/1700',
            'childCount': 2,
            'leafCount': 10,
            'viewedLeafCount': 10,
            'addedAt': 1700000000,
            'Genre': [
              {'tag': 'Drama'},
            ],
            'Guid': [
              {'id': 'tmdb://42'},
              {'id': 'imdb://tt0042'},
            ],
          },
        ],
      }),
      _ => _mc({}),
    };
    final client = _client(fake);
    final page = await client.items(parentId: '2', sortBy: 'SortName', sortOrder: 'Ascending');
    final it = page.items.single;
    expect(page.total, 1);
    expect(it.id, '100');
    expect(it.kind, MediaKind.series);
    expect(it.tmdbId, '42');
    expect(it.imdbId, 'tt0042');
    expect(it.played, isTrue);
    expect(it.childCount, 2);
    expect(it.primary?.tag, '/library/metadata/100/thumb/1700');
    expect(it.dateCreated, DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000));
    final q = fake.requests.last.queryParameters;
    expect(q['type'], '2');
    expect(q['sort'], 'titleSort');
    expect(q['includeGuids'], '1');

    final img = client.image(it.primary!, maxWidth: 300);
    expect(img.url.path, '/photo/:/transcode');
    expect(img.url.queryParameters['url'], '/library/metadata/100/thumb/1700');
    expect(img.url.queryParameters['X-Plex-Token'], 'server-token');
  });

  test('建索引时各库首尾相接分页，总数是各库之和', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    List<Map<String, dynamic>> range(String prefix, int from, int n) => [
      for (var i = from; i < from + n; i++) {'ratingKey': '$prefix$i', 'type': prefix == 'm' ? 'movie' : 'show'},
    ];
    fake.body = (uri) {
      final start = int.parse(uri.queryParameters['X-Plex-Container-Start'] ?? '0');
      final size = int.parse(uri.queryParameters['X-Plex-Container-Size'] ?? '0');
      return switch (uri.path) {
        '/library/sections' => _mc(_sections),
        '/library/sections/1/all' => _mc({'totalSize': 3, 'Metadata': range('m', start, (3 - start).clamp(0, size))}),
        '/library/sections/2/all' => _mc({'totalSize': 4, 'Metadata': range('s', start, (4 - start).clamp(0, size))}),
        _ => _mc({}),
      };
    };
    final client = _client(fake);
    final ids = <String>[];
    var start = 0;
    while (true) {
      final page = await client.items(start: start, limit: 2, fields: EmbyClient.indexFields, userData: false);
      expect(page.total, 7);
      if (page.receivedCount == 0) break;
      ids.addAll(page.items.map((i) => i.id));
      start += page.receivedCount;
    }
    expect(ids, ['m0', 'm1', 'm2', 's0', 's1', 's2', 's3']);
  });

  test('最近添加：剧集的集换成所属剧，同一部剧只出现一次', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.body = (uri) => _mc({
      'Metadata': [
        {'ratingKey': '11', 'type': 'episode', 'grandparentRatingKey': '100', 'grandparentTitle': '剧 A'},
        {'ratingKey': '12', 'type': 'episode', 'grandparentRatingKey': '100', 'grandparentTitle': '剧 A'},
        {'ratingKey': '20', 'type': 'movie', 'title': '电影 B'},
      ],
    });
    final list = await _client(fake).latest(parentId: '2', limit: 5);
    expect(list.map((i) => (i.id, i.kind, i.name)), [
      ('100', MediaKind.series, '剧 A'),
      ('20', MediaKind.movie, '电影 B'),
    ]);
    expect(fake.requests.single.path, '/library/sections/2/recentlyAdded');
  });

  test('播放信息：版本、音轨字幕、直链和外挂字幕地址', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.body = (_) => _mc({
      'Metadata': [
        {
          'ratingKey': '20',
          'type': 'movie',
          'Media': [
            {
              'id': 5,
              'container': 'mkv',
              'bitrate': 20000,
              'duration': 7200000,
              'Part': [
                {
                  'id': 77,
                  'key': '/library/parts/77/1700/file.mkv',
                  'file': '/data/movies/B.mkv',
                  'size': 123,
                  'container': 'mkv',
                  'Stream': [
                    {'streamType': 1, 'index': 0, 'codec': 'hevc', 'width': 3840, 'height': 2160, 'DOVIPresent': true},
                    {
                      'streamType': 2,
                      'index': 1,
                      'codec': 'dca',
                      'channels': 6,
                      'languageCode': 'chi',
                      'default': true,
                    },
                    {'streamType': 3, 'id': 900, 'codec': 'srt', 'key': '/library/streams/900', 'languageCode': 'eng'},
                  ],
                },
              ],
            },
          ],
        },
      ],
    });
    final client = _client(fake);
    final info = await client.playbackInfo('20');
    final s = info.sources.single;
    expect(s.id, '77');
    expect(s.bitrate, 20000000);
    expect(s.duration, const Duration(hours: 2));
    expect(s.name, 'B.mkv');
    expect(s.resolutionLabel, '4K');
    expect(s.video?.range, VideoRange.dolbyVision);
    expect(s.audio.single.codec, 'dts');
    expect(s.subtitles.single.isExternal, isTrue);

    final stream = client.stream(s);
    expect(stream.url.path, '/library/parts/77/1700/file.mkv');
    expect(stream.url.queryParameters['X-Plex-Token'], 'server-token');
    final sub = client.subtitle(s, s.subtitles.single)!;
    expect(sub.url.path, '/library/streams/900');
    expect(sub.url.queryParameters['X-Plex-Token'], 'server-token');
  });

  test('进度上报用 /:/timeline，停止时 state=stopped', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    final client = _client(fake);
    const source = MediaSourceInfo(
      serverId: 'p',
      itemId: '20',
      id: '77',
      container: 'mkv',
      duration: Duration(minutes: 100),
    );
    expect(await client.reportStopped(source, const Duration(minutes: 30), 'sess'), isTrue);
    final q = fake.requests.single;
    expect(q.path, '/:/timeline');
    expect(q.queryParameters['state'], 'stopped');
    expect(q.queryParameters['time'], '${30 * 60 * 1000}');
    expect(q.queryParameters['duration'], '${100 * 60 * 1000}');
    expect(q.queryParameters['key'], '/library/metadata/20');
  });

  test('片头片尾标记转成服务器片段', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.body = (_) => _mc({
      'Metadata': [
        {
          'ratingKey': '11',
          'type': 'episode',
          'Marker': [
            {'type': 'intro', 'startTimeOffset': 1000, 'endTimeOffset': 61000},
            {'type': 'credits', 'startTimeOffset': 1300000, 'endTimeOffset': 1400000},
          ],
        },
      ],
    });
    final segs = await _client(fake).mediaSegments('11');
    expect(segs.map((s) => (s.type, s.start.inSeconds, s.end.inSeconds)), [('Intro', 1, 61), ('Outro', 1300, 1400)]);
    expect(fake.requests.single.queryParameters['includeMarkers'], '1');
  });

  test('继续观看：以前看完过、这次重看到一半的也保留；没开始的下一集不放', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.body = (_) => _mc({
      'Metadata': [
        {'ratingKey': '1', 'type': 'movie', 'viewCount': 1, 'viewOffset': 60000, 'duration': 600000},
        {'ratingKey': '2', 'type': 'episode', 'viewOffset': 0},
      ],
    });
    final list = await _client(fake).resume();
    expect(list.map((i) => i.id), ['1']);
  });

  test('最近添加合并成剧时保留分级，儿童模式能过滤', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.body = (_) => _mc({
      'Metadata': [
        {'ratingKey': '11', 'type': 'episode', 'grandparentRatingKey': '100', 'contentRating': 'TV-MA'},
      ],
    });
    final list = await _client(fake).latest();
    expect(list.single.officialRating, 'TV-MA');
  });

  test('分成多个文件的版本：名称写明只能播第 1 段，时长用第 1 段的', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.body = (_) => _mc({
      'Metadata': [
        {
          'ratingKey': '20',
          'type': 'movie',
          'Media': [
            {
              'id': 5,
              'duration': 7200000,
              'Part': [
                {'id': 1, 'key': '/library/parts/1/0/file.avi', 'file': '/m/A cd1.avi', 'duration': 3600000},
                {'id': 2, 'key': '/library/parts/2/0/file.avi', 'file': '/m/A cd2.avi', 'duration': 3600000},
              ],
            },
          ],
        },
      ],
    });
    final s = (await _client(fake).playbackInfo('20')).sources.single;
    expect(s.name, 'A cd1.avi · 共 2 段，只能播放第 1 段');
    expect(s.duration, const Duration(hours: 1));
  });

  test('儿童模式：Plex 没有服务器端过滤，集也按分级过滤', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.body = (_) => _mc({
      'Metadata': [
        {'ratingKey': '1', 'type': 'episode', 'contentRating': 'TV-MA', 'viewOffset': 1000},
        {'ratingKey': '2', 'type': 'episode', 'contentRating': 'TV-Y', 'viewOffset': 1000},
      ],
    });
    final server = ServerConfig(
      id: 'p',
      type: ServerType.plex,
      name: 'plex',
      username: '',
      userId: 'u',
      token: 't',
      lines: [ServerLine(id: 'l', name: 'main', url: fake.url)],
    );
    final config = AppConfig(servers: [server], parental: const ParentalConfig(enabled: true, maxAge: 7));
    final client = mediaServerClient(config: config, server: server, appVersion: 'test');
    expect((await client.resume()).map((i) => i.id), ['2']);
  });
}
