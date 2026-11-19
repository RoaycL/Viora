import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/data/subtitles/online_subtitles.dart';

/// 本地假服务器：按路径返回预设内容，记下收到的请求
class _FakeServer {
  late HttpServer server;
  final requests = <HttpRequest>[];
  final bodies = <String>[];
  final routes = <String, Object Function(HttpRequest)>{};

  String get base => 'http://${server.address.host}:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests.add(req);
      bodies.add(await utf8.decodeStream(req));
      final handler = routes[req.uri.path];
      if (handler == null) {
        req.response.statusCode = 404;
      } else {
        final out = handler(req);
        if (out is List<int>) {
          req.response.add(out);
        } else {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(out));
        }
      }
      await req.response.close();
    });
  }
}

void main() {
  test('OpenSubtitles 搜索参数：剧集用剧的 TMDB ID + 季集，参数按字母排序；电影用自己的 ID', () {
    final ep = OpenSubtitlesClient.searchParams(
      const SubtitleQuery(title: '指环王', tmdbId: 84773, imdbId: 'tt7631058', season: 1, episode: 2),
      SubtitleLanguage.chinese,
    );
    expect(ep.keys.toList(), ['episode_number', 'languages', 'parent_tmdb_id', 'season_number']);
    expect(ep['languages'], 'zh-cn,zh-tw');
    expect(ep['parent_tmdb_id'], '84773');

    final movie = OpenSubtitlesClient.searchParams(
      const SubtitleQuery(title: '盗梦空间', imdbId: 'tt1375666'),
      SubtitleLanguage.english,
    );
    expect(movie, {'imdb_id': '1375666', 'languages': 'en'});

    final noId = OpenSubtitlesClient.searchParams(
      const SubtitleQuery(title: '某片', originalTitle: 'Some Movie', year: 2020),
      SubtitleLanguage.english,
    );
    expect(noId, {'languages': 'en', 'query': 'some movie', 'year': '2020'});
  });

  test('OpenSubtitles：带内置 Key 搜索，按下载量排序；下载拿到地址后取回文件', () async {
    final s = _FakeServer();
    await s.start();
    addTearDown(() => s.server.close(force: true));
    s.routes['/api/v1/subtitles'] = (_) => {
      'data': [
        {
          'attributes': {
            'language': 'en',
            'download_count': 10,
            'release': 'Show.S01E02.720p',
            'files': [
              {'file_id': 111, 'file_name': 'a.srt'},
            ],
          },
        },
        {
          'attributes': {
            'language': 'en',
            'download_count': 99,
            'release': 'Show.S01E02.1080p',
            'files': [
              {'file_id': 222, 'file_name': 'b.srt'},
            ],
          },
        },
        {'attributes': {'files': <Object>[]}},
      ],
    };
    s.routes['/api/v1/download'] = (_) => {'link': '${s.base}/file/b.srt', 'file_name': 'b.srt', 'remaining': 4};
    s.routes['/file/b.srt'] = (_) => utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nHello\n');

    final client = OpenSubtitlesClient(const SubtitleSourcesConfig(), apiKey: 'key', baseUrl: '${s.base}/api/v1');
    final list = await client.search(
      const SubtitleQuery(title: 'Show', tmdbId: 1, season: 1, episode: 2),
      SubtitleLanguage.english,
    );
    expect(list.map((x) => x.id), ['222', '111']);
    expect(list.first.name, 'Show.S01E02.1080p');
    expect(s.requests.first.headers.value('Api-Key'), 'key');
    expect(s.requests.first.headers.value('User-Agent'), startsWith('Viora v'));

    final file = await client.download(list.first);
    expect(file.fileName, 'b.srt');
    expect(utf8.decode(file.bytes), contains('Hello'));
    expect(jsonDecode(s.bodies[1]), {'file_id': 222});
    // 没登录：不带 Authorization
    expect(s.requests[1].headers.value('Authorization'), isNull);
  });

  test('OpenSubtitles：没有内置 Key 时不发请求；下载次数用完时提示登录', () async {
    final s = _FakeServer();
    await s.start();
    addTearDown(() => s.server.close(force: true));
    s.routes['/api/v1/download'] = (req) {
      req.response.statusCode = 406;
      return {'message': 'You have downloaded your allowed 5 subtitles for 24h'};
    };
    final none = OpenSubtitlesClient(const SubtitleSourcesConfig(), apiKey: '', baseUrl: '${s.base}/api/v1');
    expect(await none.search(const SubtitleQuery(title: 'x'), SubtitleLanguage.english), isEmpty);
    expect(s.requests, isEmpty);

    final client = OpenSubtitlesClient(const SubtitleSourcesConfig(), apiKey: 'key', baseUrl: '${s.base}/api/v1');
    await expectLater(
      client.download(const OnlineSubtitle(provider: 'OpenSubtitles', id: '1', name: 'x')),
      throwsA(isA<OnlineSubtitleException>().having((e) => e.message, 'message', contains('登录'))),
    );
  });

  test('射手网（伪）：英文原名搜不到再用中文名；只留所选语言；下载时挑简体的文本字幕', () async {
    final s = _FakeServer();
    await s.start();
    addTearDown(() => s.server.close(force: true));
    s.routes['/v1/sub/search'] = (req) {
      final q = req.uri.queryParameters['q']!;
      if (q.startsWith('The Rings')) return {'status': 0, 'sub': {'subs': <Object>[]}};
      return {
        'status': 0,
        'sub': {
          'subs': [
            {
              'id': 1,
              'native_name': '指环王 力量之戒 第一季',
              'subtype': 'ASS',
              'lang': {
                'desc': '简 英',
                'langlist': {'langchs': true, 'langeng': true},
              },
            },
            {
              'id': 2,
              'videoname': 'only.english',
              'lang': {
                'desc': '英',
                'langlist': {'langeng': true},
              },
            },
          ],
        },
      };
    };
    s.routes['/v1/sub/detail'] = (_) => {
      'status': 0,
      'sub': {
        'subs': [
          {
            'filelist': [
              {'url': '${s.base}/f/readme.txt', 'f': 'readme.txt'},
              {'url': '${s.base}/f/x.cht.srt', 'f': 'x.cht.srt'},
              {'url': '${s.base}/f/x.chs.ass', 'f': 'x.chs.ass'},
            ],
          },
        ],
      },
    };
    s.routes['/f/x.chs.ass'] = (_) => utf8.encode('[Script Info]');

    final client = AssrtClient('tok', baseUrl: '${s.base}/v1');
    final list = await client.search(
      const SubtitleQuery(title: '指环王：力量之戒', originalTitle: 'The Rings of Power', season: 1, episode: 2),
      SubtitleLanguage.chinese,
    );
    expect(list.map((x) => x.id), ['1']);
    expect(list.single.language, '简 英');
    final queries = [for (final r in s.requests) r.uri.queryParameters['q']];
    expect(queries, ['The Rings of Power S01E02', '指环王：力量之戒 S01E02']);
    expect(s.requests.first.uri.queryParameters['token'], 'tok');

    final file = await client.download(list.single);
    expect(file.fileName, 'x.chs.ass');
    expect(utf8.decode(file.bytes), '[Script Info]');
  });

  test('射手网（伪）：token 不对时给出原因；只有压缩包时提示换一条', () async {
    final s = _FakeServer();
    await s.start();
    addTearDown(() => s.server.close(force: true));
    s.routes['/v1/sub/search'] = (req) {
      req.response.statusCode = 401;
      return {'status': 20001, 'errmsg': 'invalid token'};
    };
    s.routes['/v1/sub/detail'] = (_) => {
      'status': 0,
      'sub': {
        'subs': [
          {'filename': 'pack.rar', 'url': '${s.base}/pack.rar', 'filelist': <Object>[]},
        ],
      },
    };
    final client = AssrtClient('bad', baseUrl: '${s.base}/v1');
    // 太短的名字（《Up》）不发请求：直接换下一个名字
    expect(await client.search(const SubtitleQuery(title: 'Up'), SubtitleLanguage.english), isEmpty);
    expect(s.requests, isEmpty);
    await expectLater(
      client.search(const SubtitleQuery(title: 'Friends'), SubtitleLanguage.chinese),
      throwsA(isA<OnlineSubtitleException>().having((e) => e.message, 'message', contains('token'))),
    );
    await expectLater(
      client.download(const OnlineSubtitle(provider: '射手网（伪）', id: '9', name: 'x')),
      throwsA(isA<OnlineSubtitleException>().having((e) => e.message, 'message', contains('压缩包'))),
    );
  });

  test('射手网（伪）字幕包：搜英文时挑英文文件，搜中文时挑简体', () {
    final files = [
      {'f': 'movie.chs.srt'},
      {'f': 'movie.en.srt'},
      {'f': 'movie.cht.srt'},
    ];
    expect(AssrtClient.pickFile(files, SubtitleLanguage.english)!['f'], 'movie.en.srt');
    expect(AssrtClient.pickFile(files, SubtitleLanguage.chinese)!['f'], 'movie.chs.srt');
    expect(AssrtClient.pickFile(files)!['f'], 'movie.chs.srt');
  });

  test('射手网（伪）整季字幕包：挑正在看的那一集；包里没有这一集时不乱挑', () {
    final files = [
      {'f': 'Show.S01E01.chs.ass'},
      {'f': 'Show.S01E02.chs.ass'},
      {'f': 'Show.S01E02.eng.srt'},
    ];
    expect(AssrtClient.pickFile(files, SubtitleLanguage.chinese, 1, 2)!['f'], 'Show.S01E02.chs.ass');
    expect(AssrtClient.pickFile(files, SubtitleLanguage.english, 1, 2)!['f'], 'Show.S01E02.eng.srt');
    expect(AssrtClient.pickFile(files, SubtitleLanguage.chinese, 1, 5), isNull);
    // 文件名里认不出集数（单集字幕）：照常挑
    expect(AssrtClient.pickFile([{'f': 'a.chs.srt'}], SubtitleLanguage.chinese, 1, 5)!['f'], 'a.chs.srt');
    expect(AssrtClient.episodeOf('[字幕组] 某剧 第03集.ass'), (null, 3));
    expect(AssrtClient.episodeOf('show.1x04.srt'), (1, 4));
  });

  test('OpenSubtitles：登录令牌被拒（过期）时重新登录再下载一次', () async {
    final s = _FakeServer();
    await s.start();
    addTearDown(() => s.server.close(force: true));
    var logins = 0, downloads = 0;
    s.routes['/api/v1/login'] = (_) => {'token': 't${++logins}'};
    s.routes['/api/v1/download'] = (req) {
      downloads++;
      if (req.headers.value('Authorization') == 'Bearer t1') {
        req.response.statusCode = 401;
        return {'message': 'token expired'};
      }
      return {'link': '${s.base}/f.srt', 'file_name': 'f.srt'};
    };
    s.routes['/f.srt'] = (_) => utf8.encode('ok');
    final client = OpenSubtitlesClient(
      const SubtitleSourcesConfig(osUsername: 'retry-user', osPassword: 'pw'),
      apiKey: 'key',
      baseUrl: '${s.base}/api/v1',
    );
    final file = await client.download(const OnlineSubtitle(provider: 'OpenSubtitles', id: '5', name: 'x'));
    expect(utf8.decode(file.bytes), 'ok');
    expect(logins, 2);
    expect(downloads, 2);
  });

  test('保存字幕：去掉 UTF-8 BOM、UTF-16 转成 UTF-8，文件名保留扩展名', () async {
    expect(normalizeSubtitleBytes([0xEF, 0xBB, 0xBF, 0x41]), [0x41]);
    final utf16le = [0xFF, 0xFE, ...'中a'.codeUnits.expand((u) => [u & 0xFF, u >> 8])];
    expect(utf8.decode(normalizeSubtitleBytes(utf16le)), '中a');
    final gbk = [0xD6, 0xD0];
    expect(normalizeSubtitleBytes(gbk), gbk, reason: '其他编码原样保留');

    final dir = await Directory.systemTemp.createTemp('viora_sub');
    addTearDown(() => dir.delete(recursive: true));
    final path = await saveSubtitleFile(SubtitleFile('a/b:c.chs.ass', utf8.encode('x')), dir: dir);
    expect(path, endsWith('b_c.chs.ass'));
    expect(path, isNot(contains('a/b')));
    final noExt = await saveSubtitleFile(SubtitleFile('12345', utf8.encode('x')), dir: dir);
    expect(noExt, endsWith('.srt'));
  });

  test('在线字幕设置：OpenSubtitles 密码存进密钥库，配置文件里没有明文', () async {
    SharedPreferences.setMockInitialValues({});
    final vault = MemoryVault();
    ConfigStore.vault = vault;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(configProvider.notifier);
    await store.load();
    await store.update(
      (c) => c.copyWith(
        subtitles: const SubtitleSourcesConfig(osUsername: 'me', osPassword: 'pw', assrtToken: 'tok'),
      ),
    );
    final json =
        jsonDecode((await SharedPreferences.getInstance()).getString('viora.config.v1')!) as Map<String, dynamic>;
    expect(json['subtitles'], {'osUsername': 'me', 'osPassword': '', 'assrtToken': 'tok'});
    expect(vault.values.values, contains('pw'));

    // 重新读入：密码从密钥库补回来
    final again = ProviderContainer();
    addTearDown(again.dispose);
    await again.read(configProvider.notifier).load();
    final c = again.read(configProvider).subtitles;
    expect(c.osPassword, 'pw');
    expect(c.osLoggedIn, isTrue);
    expect(c.assrtEnabled, isTrue);
  });
}
