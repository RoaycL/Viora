import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/media/media_models.dart';

/// 收到的一个请求
class _Req {
  _Req(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final HttpHeaders headers;
  final String body;

  Map<String, dynamic> get json => body.isEmpty ? const {} : jsonDecode(body) as Map<String, dynamic>;
}

String _md5(String s) => md5.convert(utf8.encode(s)).toString();

/// 本机假飞牛影视：校验 Authx 签名（和真服务器一样的算法），按路径返回 `{code, msg, data}`
class _Fake {
  _Fake(this.http);
  final HttpServer http;
  final requests = <_Req>[];

  /// 当前有效的令牌
  String token = 'tok-1';
  int logins = 0;
  Object? Function(_Req r) data = (_) => null;

  /// 非空时代替 /user/info 的响应
  Map<String, Object?>? Function(_Req r) infoOverride = (_) => null;

  static Future<_Fake> start() async {
    final f = _Fake(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    f.http.listen((request) async {
      final body = await utf8.decodeStream(request);
      final r = _Req(request.method, request.uri, request.headers, body);
      f.requests.add(r);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(f._reply(r)));
      await request.response.close();
    });
    return f;
  }

  Map<String, Object?> _reply(_Req r) {
    if (!_signed(r)) return {'code': 5000, 'msg': 'invalid sign', 'data': null};
    if (r.uri.path == '/v/api/v1/login') {
      logins++;
      if (r.json['password'] != 'pw') return {'code': -15, 'msg': 'Password Incorrect', 'data': null};
      return {
        'code': 0,
        'msg': '',
        'data': {'token': token},
      };
    }
    if (r.headers.value('Authorization') != token) return {'code': -2, 'msg': 'Auth Failed', 'data': null};
    if (r.uri.path == '/v/api/v1/user/info') {
      final o = infoOverride(r);
      if (o != null) return o;
      return {
        'code': 0,
        'msg': '',
        'data': {'guid': 'user-guid', 'username': 'u'},
      };
    }
    return {'code': 0, 'msg': '', 'data': data(r)};
  }

  /// 按飞牛的规则验签：md5(key_路径_nonce_时间戳_内容摘要_secret)
  static bool _signed(_Req r) {
    final authx = Uri.splitQueryString(r.headers.value('Authx') ?? '');
    final String digest;
    if (r.body.isNotEmpty) {
      digest = _md5(r.body);
    } else if (r.uri.queryParameters.isNotEmpty) {
      final keys = r.uri.queryParameters.keys.toList()..sort();
      digest = _md5(keys.map((k) => '$k=${r.uri.queryParameters[k]}').join('&'));
    } else {
      digest = _md5('');
    }
    final sign = _md5(
      [
        'NDzZTVxnRKP8Z0jXg1VAMonaG8akvh',
        r.uri.path,
        authx['nonce'],
        authx['timestamp'],
        digest,
        '16CCEB3D-AB42-077D-36A1-F355324E4237',
      ].join('_'),
    );
    return authx['sign'] == sign;
  }

  String get url => 'http://127.0.0.1:${http.port}';

  Iterable<_Req> to(String path) => requests.where((r) => r.uri.path == '/v/api/v1$path');
}

EmbyClient _client(_Fake fake, {String? token = 'tok-1', String url = ''}) {
  final server = ServerConfig(
    id: 'f',
    type: ServerType.fnos,
    name: 'nas',
    username: 'u',
    password: 'pw',
    userId: token == null ? null : 'user-guid',
    token: token,
    lines: [ServerLine(id: 'l', name: 'main', url: url.isEmpty ? fake.url : url)],
  );
  return mediaServerClient(
    config: AppConfig(servers: [server]),
    server: server,
    appVersion: 'test',
  );
}

const _movieDb = 'db-movie';
const _tvDb = 'db-tv';

Map<String, Object?> _movie(String guid, {int ts = 0, int watched = 0}) => {
  'guid': guid,
  'type': 'Movie',
  'title': '电影 $guid',
  'poster': '/0c/09/$guid.webp',
  'vote_average': '7.5',
  'release_date': '2025-01-29',
  'runtime': 144,
  'duration': 8716,
  'imdb_id': 'tt0042',
  'genres': [1, 99],
  'is_favorite': 1,
  'watched': watched,
  'ts': ts,
  'ancestor_guid': _movieDb,
  'parent_guid': '',
};

void main() {
  setUp(EmbyClient.clearRecentItems);

  test('签名算法：GET 摘要按参数名排序，POST 摘要是请求体', () {
    final a = fnosAuthx('/v/api/v1/search/list', query: {'q': '封神', 'a': '1'}, nonce: 123456, timestamp: 1);
    final b = fnosAuthx('/v/api/v1/search/list', query: {'a': '1', 'q': '封神'}, nonce: 123456, timestamp: 1);
    expect(a, b);
    expect(a, startsWith('nonce=123456&timestamp=1&sign='));
    expect(fnosPayloadDigest(), _md5(''));
    expect(fnosPayloadDigest(body: '{"a":1}'), _md5('{"a":1}'));
    expect(fnosPayloadDigest(query: {'q': '封神', 'a': '1'}), _md5('a=1&q=封神'));
  });

  test('登录：账号密码换令牌，用户 ID 用飞牛的用户 guid；密码错误提示清楚', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    final client = _client(fake, token: null);
    expect(client, isA<FnosClient>());
    final s = await client.login();
    expect(s.token, 'tok-1');
    expect(s.userId, 'user-guid');
    final login = fake.to('/login').single;
    expect(login.method, 'POST');
    expect(login.json['app_name'], 'trimemedia-web');
    expect(login.json['username'], 'u');
    expect(login.json['nonce'], matches(RegExp(r'^\d{6}$')));

    final bad = mediaServerClient(
      config: const AppConfig(),
      server: s.copyWith(password: 'wrong', clearSession: true),
      appVersion: 'test',
    );
    await expectLater(bad.login(), throwsA(isA<MediaServerException>().having((e) => e.statusCode, 'statusCode', 401)));
  });

  test('令牌失效（code -2）时用保存的密码重新登录再重试', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.token = 'tok-2';
    fake.data = (r) => {'movie': 2, 'tv': 1};
    final client = _client(fake);
    final c = await client.counts();
    expect((c.movies, c.series), (2, 1));
    expect(fake.logins, 1);
    expect(client.server.token, 'tok-2');
    expect(fake.to('/mediadb/sum').last.headers.value('Authorization'), 'tok-2');
  });

  test('媒体库、条目列表：按页码分页、类型和排序映射、解析条目', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.data = (r) => switch (r.uri.path) {
      '/v/api/v1/mediadb/list' => [
        {'guid': _tvDb, 'title': '电视剧', 'category': 'TV', 'poster': '/d9/tv.webp'},
        {
          'guid': _movieDb,
          'title': '电影',
          'category': 'Movie',
          'posters': ['/a6/m.webp'],
        },
        {'guid': 'db-live', 'title': '直播', 'category': 'Live'},
      ],
      '/v/api/v1/tag/genres' => [
        {'id': 1, 'value': 'Action'},
      ],
      '/v/api/v1/item/list' => {
        'total': 130,
        'list': [for (var i = 0; i < (r.json['page_size'] as int); i++) _movie('m${r.json['page']}-$i')],
      },
      _ => null,
    };
    final client = _client(fake);
    final libs = await client.libraries();
    expect(libs.map((l) => (l.id, l.collectionType, l.image?.tag)), [
      (_tvDb, 'tvshows', '/d9/tv.webp'),
      (_movieDb, 'movies', '/a6/m.webp'),
    ]);

    final page = await client.items(
      parentId: _movieDb,
      start: 60,
      limit: 60,
      sortBy: 'SortName',
      sortOrder: 'Ascending',
    );
    final req = fake.to('/item/list').single.json;
    expect(req['ancestor_guid'], _movieDb);
    expect(req['page'], 2);
    expect(req['page_size'], 60);
    expect(req['sort_column'], 'sort_title');
    expect(req['sort_type'], 'ASC');
    expect(req['tags'], {
      'type': ['Movie', 'TV'],
    });
    expect(page.total, 130);
    expect(page.items, hasLength(60));
    final it = page.items.first;
    expect(it.id, 'm2-0');
    expect(it.kind, MediaKind.movie);
    expect(it.year, 2025);
    expect(it.rating, 7.5);
    expect(it.runtime, const Duration(seconds: 8716));
    expect(it.imdbId, 'tt0042');
    expect(it.genres, ['动作']);
    expect(it.favorite, isTrue);
    expect(it.primary?.tag, '/0c/09/m2-0.webp');

    // 起点不是页大小的整数倍：取两页拼起来
    fake.requests.clear();
    final odd = await client.items(parentId: _movieDb, start: 30, limit: 60);
    expect(fake.to('/item/list').map((r) => r.json['page']), [1, 2]);
    expect(odd.items.map((i) => i.id).first, 'm1-30');
    expect(odd.items.map((i) => i.id).last, 'm2-29');
    expect(odd.items, hasLength(60));

    // 只要剧集
    fake.requests.clear();
    await client.items(types: 'Series', sortBy: 'DateCreated', sortOrder: 'Descending', limit: 10);
    final tv = fake.to('/item/list').single.json;
    expect(tv['tags'], {
      'type': ['TV'],
    });
    expect(tv['sort_column'], 'create_time');
    expect(tv['sort_type'], 'DESC');
  });

  test('搜索用 /search/list，收藏用 /favorite/list，最近看过用播放记录', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.data = (r) => switch (r.uri.path) {
      '/v/api/v1/search/list' => [
        _movie('a'),
        {'guid': 'tv', 'type': 'TV', 'title': '剧', 'ancestor_guid': _tvDb},
        {'guid': 'p', 'type': 'Person', 'title': '人'},
      ],
      '/v/api/v1/favorite/list' => {'total': 0, 'list': null},
      '/v/api/v1/play/list' => [_movie('r', ts: 100)],
      _ => null,
    };
    final client = _client(fake);
    final found = await client.items(searchTerm: ' 封神 ', limit: 20);
    expect(found.items.map((i) => i.id), ['a', 'tv']);
    expect(fake.to('/search/list').single.uri.queryParameters, {'q': '封神'});

    final fav = await client.items(filters: 'IsFavorite', sortBy: 'SortName', sortOrder: 'Ascending');
    expect(fav.items, isEmpty);
    expect(fav.total, 0);

    final played = await client.items(
      types: 'Movie,Episode',
      filters: 'IsPlayed',
      sortBy: 'DatePlayed',
      sortOrder: 'Descending',
    );
    expect(played.items.single.id, 'r');
  });

  test('继续观看：集通过所属季找到剧集', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.data = (r) => switch (r.uri.path) {
      '/v/api/v1/play/list' => [
        {
          'guid': 'ep5',
          'type': 'Episode',
          'title': '墓中惊现七星疑棺',
          'tv_title': '盗墓笔记',
          'parent_guid': 'season1',
          'poster': '/0f/16/ep.webp',
          'season_number': 1,
          'episode_number': 5,
          'runtime': 40,
          'ts': 1748,
          'duration': 2575,
          'watched': 0,
        },
        _movie('done'),
      ],
      '/v/api/v1/item/season1' => {'guid': 'season1', 'type': 'Season', 'parent_guid': 'series'},
      _ => null,
    };
    final client = _client(fake);
    final list = await client.resume();
    final ep = list.single;
    expect(ep.kind, MediaKind.episode);
    expect(ep.seriesId, 'series');
    expect(ep.seriesName, '盗墓笔记');
    expect(ep.seasonId, 'season1');
    expect((ep.seasonNumber, ep.episodeNumber), (1, 5));
    expect(ep.position, const Duration(seconds: 1748));
    expect(ep.playedPercentage, closeTo(1748 * 100 / 2575, 0.01));
    expect(ep.thumb?.tag, '/0f/16/ep.webp');
    expect(client.recentItem('ep5'), isNotNull);

    // 季对应的剧集记住了，不再重复查
    await client.resume();
    expect(fake.to('/item/season1'), hasLength(1));
  });

  test('季、集、下一集', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    Map<String, Object?> ep(int n, {int watched = 0, int ts = 0}) => {
      'guid': 'e$n',
      'type': 'Episode',
      'title': '第 $n 集',
      'parent_guid': 's1',
      'season_number': 1,
      'episode_number': n,
      'duration': 2500,
      'watched': watched,
      'ts': ts,
    };
    fake.data = (r) => switch (r.uri.path) {
      '/v/api/v1/season/list/show' => [
        {
          'guid': 's1',
          'type': 'Season',
          'title': '第 1 季',
          'season_number': 1,
          'parent_guid': 'show',
          'local_number_of_episodes': 3,
        },
      ],
      '/v/api/v1/episode/list/s1' => [ep(1, watched: 1), ep(2), ep(3)],
      _ => null,
    };
    final client = _client(fake);
    final seasons = await client.seasons('show');
    expect(seasons.single.kind, MediaKind.season);
    expect(seasons.single.seriesId, 'show');
    expect(seasons.single.childCount, 3);

    final eps = await client.episodes('show');
    expect(eps.map((e) => e.id), ['e1', 'e2', 'e3']);
    expect(eps.first.played, isTrue);
    expect(eps.every((e) => e.seriesId == 'show'), isTrue);

    expect((await client.nextUp('show'))?.id, 'e2');
  });

  test('播放：版本和音视频流、NAS 文件地址带令牌、进度上报带流 guid', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.data = (r) => switch (r.uri.path) {
      '/v/api/v1/stream/list/ep5' => {
        'files': [
          {'guid': 'fileA', 'file_name': 'a.mkv', 'size': 100, 'can_play': 1},
          {'guid': 'fileB', 'file_name': 'b.S01E05.mp4', 'size': 200, 'can_play': 1},
        ],
        'video_streams': [
          {
            'media_guid': 'fileB',
            'guid': 'vB',
            'codec_name': 'hevc',
            'index': 0,
            'width': 1920,
            'height': 1000,
            'bit_depth': 8,
            'avg_frame_rate': '24 fps',
            'color_range_type': 'HDR10',
            'duration': 2575,
            'bps': 4000000,
          },
          {'media_guid': 'fileA', 'guid': 'vA', 'codec_name': 'h264', 'index': 0, 'duration': 2575},
        ],
        'audio_streams': [
          {
            'media_guid': 'fileB',
            'guid': 'aB1',
            'codec_name': 'aac',
            'language': 'und',
            'channels': 2,
            'index': 1,
            'is_default': 0,
          },
          {
            'media_guid': 'fileB',
            'guid': 'aB2',
            'codec_name': 'eac3',
            'language': 'chi',
            'channels': 6,
            'index': 2,
            'is_default': 1,
          },
        ],
        'subtitle_streams': [
          {
            'media_guid': 'fileB',
            'guid': 'sub1',
            'codec_name': '',
            'format': 'srt',
            'language': 'chi',
            'index': 3,
            'is_external': 1,
          },
        ],
      },
      '/v/api/v1/play/info' => {'media_guid': 'fileB', 'ts': 1748},
      '/v/api/v1/play/record' => true,
      '/v/api/v1/item/watched' => true,
      _ => null,
    };
    final client = _client(fake);
    final info = await client.playbackInfo('ep5');
    expect(info.sources.map((s) => s.id), ['fileB', 'fileA'], reason: '上次播放的版本排第一');
    final b = info.sources.first;
    expect(b.container, 'mp4');
    expect(b.duration, const Duration(seconds: 2575));
    final v = b.streams.firstWhere((s) => s.type == 'Video');
    expect((v.codec, v.width, v.frameRate, v.range), ('hevc', 1920, 24.0, VideoRange.hdr10));
    final audio = b.streams.where((s) => s.type == 'Audio').toList();
    expect(audio.map((a) => (a.index, a.language, a.isDefault)), [(1, null, false), (2, 'chi', true)]);
    final sub = b.streams.singleWhere((s) => s.type == 'Subtitle');
    expect(sub.isExternal, isTrue);

    final req = client.stream(b);
    expect(req.url.toString(), '${fake.url}/v/api/v1/media/range/fileB');
    expect(req.headers['Authorization'], 'tok-1');

    final subReq = client.subtitle(b, sub)!;
    expect(subReq.url.path, '/v/api/v1/subtitle/dl/sub1');
    expect(subReq.headers['Authx'], startsWith('nonce='));

    await client.reportProgress(b, const Duration(seconds: 1800, milliseconds: 600), null);
    final rec = fake.to('/play/record').single.json;
    expect(rec['item_guid'], 'ep5');
    expect(rec['media_guid'], 'fileB');
    expect(rec['video_guid'], 'vB');
    expect(rec['audio_guid'], 'aB2');
    expect(rec['ts'], 1800);
    expect(rec['duration'], 2575);

    await client.setPlayed('ep5', false);
    final w = fake.to('/item/watched').single;
    expect(w.method, 'DELETE');
    expect(w.json['item_guid'], 'ep5');
  });

  test('令牌过期重新登录时 /user/info 暂时出错：沿用原来的用户 guid，不当成换账号', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.token = 'tok-2';
    var infoFails = true;
    fake.data = (r) => {'movie': 1, 'tv': 0};
    final changed = <ServerConfig>[];
    final base = ServerConfig(
      id: 'f',
      type: ServerType.fnos,
      name: 'nas',
      username: 'u',
      password: 'pw',
      userId: 'user-guid',
      token: 'tok-1',
      lines: [ServerLine(id: 'l', name: 'main', url: fake.url)],
    );
    final client = mediaServerClient(
      config: AppConfig(servers: [base]),
      server: base,
      appVersion: 'test',
      onServerChanged: changed.add,
    );
    fake.infoOverride = (r) => infoFails ? {'code': -4, 'msg': 'Internal Error', 'data': null} : null;
    await client.counts();
    expect(client.server.token, 'tok-2');
    expect(client.server.userId, 'user-guid');
    expect(changed.map((s) => s.userId).toSet(), {'user-guid'});

    // 第一次登录取不到用户信息：登录失败，不先存一个别的 ID
    final fresh = mediaServerClient(
      config: const AppConfig(),
      server: base.copyWith(clearSession: true),
      appVersion: 'test',
    );
    // 新客户端从没确认过 guid
    final firstLogin = mediaServerClient(
      config: const AppConfig(),
      server: ServerConfig(
        id: 'g',
        type: ServerType.fnos,
        name: 'nas',
        username: 'u',
        password: 'pw',
        lines: [ServerLine(id: 'l', name: 'main', url: fake.url)],
      ),
      appVersion: 'test',
    );
    await expectLater(firstLogin.login(), throwsA(isA<MediaServerException>()));
    expect(firstLogin.server.loggedIn, isFalse);
    infoFails = false;
    expect((await fresh.login()).userId, 'user-guid');
  });

  test('重启后补发的停止上报：重新取播放信息补上流 guid 和时长', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.data = (r) => switch (r.uri.path) {
      '/v/api/v1/stream/list/item9' => {
        'files': [
          {'guid': 'file9', 'file_name': 'x.mkv', 'can_play': 1},
        ],
        'video_streams': [
          {'media_guid': 'file9', 'guid': 'v9', 'index': 0, 'duration': 3000},
        ],
        'audio_streams': [
          {'media_guid': 'file9', 'guid': 'a9', 'index': 1, 'is_default': 1},
        ],
      },
      '/v/api/v1/play/record' => true,
      _ => null,
    };
    final client = _client(fake);
    final ok = await client.reportStopped(
      const MediaSourceInfo(serverId: 'f', itemId: 'item9', id: 'file9', container: ''),
      const Duration(seconds: 120),
      null,
    );
    expect(ok, isTrue);
    final rec = fake.to('/play/record').single.json;
    expect((rec['video_guid'], rec['audio_guid'], rec['ts'], rec['duration']), ('v9', 'a9', 120, 3000));
  });

  test('图片走 /sys/img 按宽度缩放；地址末尾的 /v 去掉', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    final client = _client(fake, url: '${fake.url}/v/');
    final img = client.image(const ImageRef('x', ImageKind.primary, tag: '/39/09/p.webp'), maxWidth: 300);
    expect(img.url.toString(), '${fake.url}/v/api/v1/sys/img/39/09/p.webp?w=300');
    // 有的飞牛版本图片也要令牌和签名：和接口一样带上
    expect(img.headers['Cookie'], 'mode=relay');
    expect(img.headers.containsKey('Authx'), isTrue);
  });
}
