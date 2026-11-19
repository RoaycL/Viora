import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/danmaku/danmaku_client.dart';

/// 本机假弹幕服务器：记下收到的请求（路径、请求头、请求体），按路径返回 JSON
class _Fake {
  _Fake(this.http);
  final HttpServer http;
  final requests = <({String path, HttpHeaders headers, String body})>[];
  Object Function(String path) reply = (_) => const {};

  static Future<_Fake> start() async {
    final f = _Fake(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    f.http.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      f.requests.add((path: request.uri.path, headers: request.headers, body: body));
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(f.reply(request.uri.path)));
      await request.response.close();
    });
    return f;
  }

  String get url => 'http://127.0.0.1:${http.port}';
}

void main() {
  late _Fake builtin, own;
  final saved = (DanmakuConfig.builtinServer, DanmakuConfig.builtinAppId, DanmakuConfig.builtinAppSecret);

  setUp(() async {
    builtin = await _Fake.start();
    own = await _Fake.start();
    DanmakuConfig.builtinServer = builtin.url;
    DanmakuConfig.builtinAppId = 'app';
    DanmakuConfig.builtinAppSecret = 'secret';
  });
  tearDown(() async {
    DanmakuConfig.builtinServer = saved.$1;
    DanmakuConfig.builtinAppId = saved.$2;
    DanmakuConfig.builtinAppSecret = saved.$3;
    await builtin.http.close(force: true);
    await own.http.close(force: true);
  });

  test('签名：base64(sha256(AppId + 时间戳 + 路径 + Secret))', () {
    final h = dandanplaySignature('app', 'secret', '/api/v2/comment/1', 1700000000);
    expect(h['X-AppId'], 'app');
    expect(h['X-Timestamp'], '1700000000');
    expect(h['X-Signature'], base64.encode(sha256.convert(utf8.encode('app1700000000/api/v2/comment/1secret')).bytes));
  });

  test('内置弹弹play 排在自己的服务器后面；关掉或没有内置 AppId 时不参与', () {
    final config = DanmakuConfig(servers: [own.url]);
    expect(config.allServers, [own.url, builtin.url]);
    expect(config.copyWith(useBuiltin: false).allServers, [own.url]);
    expect(const DanmakuConfig().allServers, [builtin.url]);
    DanmakuConfig.builtinAppId = '';
    expect(const DanmakuConfig().allServers, isEmpty);
    expect(const DanmakuConfig().ready, isFalse);
  });

  test('开关跟着配置保存和同步', () {
    final json = const DanmakuConfig(useBuiltin: false).toJson();
    expect(DanmakuConfig.fromJson(json).useBuiltin, isFalse);
    expect(DanmakuConfig.fromJson(const {}).useBuiltin, isTrue);
    expect(const DanmakuConfig(useBuiltin: false).toSyncJson()['useBuiltin'], isFalse);
  });

  test('发往弹弹play 的请求带签名，自己的服务器不带；自动匹配只按文件名，优先用自己的服务器', () async {
    Object match(String title) => {
      'isMatched': true,
      'matches': [
        {'episodeId': 11, 'animeId': 1, 'animeTitle': title, 'episodeTitle': '第1话'},
      ],
    };
    own.reply = (_) => match('自己的');
    builtin.reply = (_) => match('弹弹play');
    final client = DanmakuClient(DanmakuConfig(servers: [own.url]));
    final m = await client.match('剧名 S01E01');
    expect(m?.server, own.url);

    final b = builtin.requests.single;
    expect(b.path, '/api/v2/match');
    expect((jsonDecode(b.body) as Map)['matchMode'], 'fileNameOnly');
    final ts = int.parse(b.headers.value('X-Timestamp')!);
    expect(b.headers.value('X-AppId'), 'app');
    expect(b.headers.value('X-Signature'), dandanplaySignature('app', 'secret', '/api/v2/match', ts)['X-Signature']);

    final o = own.requests.single;
    expect(o.headers.value('X-AppId'), isNull);
    expect((jsonDecode(o.body) as Map).containsKey('matchMode'), isFalse);
  });

  test('自己的服务器匹配不上时用弹弹play', () async {
    own.reply = (_) => {'isMatched': false, 'matches': const []};
    builtin.reply = (_) => {
      'isMatched': true,
      'matches': [
        {'episodeId': 22, 'animeId': 2, 'animeTitle': '剧名', 'episodeTitle': '第1话'},
      ],
    };
    final m = await DanmakuClient(DanmakuConfig(servers: [own.url])).match('剧名 S01E01');
    expect(m?.server, builtin.url);
    expect(m?.episodeId, 22);
  });

  test('手动搜索：弹弹play 里和自己服务器同名的作品去掉，其余标明来源', () async {
    own.reply = (_) => {
      'animes': [
        {'animeId': 1, 'animeTitle': '凡人修仙传(2020)【bilibili】', 'episodeCount': 150},
      ],
    };
    builtin.reply = (_) => {
      'animes': [
        {'animeId': 1, 'animeTitle': '凡人修仙传', 'episodeCount': 150},
        {'animeId': 2, 'animeTitle': '凡人修仙传 外传', 'episodeCount': 12},
      ],
    };
    final animes = await DanmakuClient(DanmakuConfig(servers: [own.url])).search('凡人修仙传');
    expect(animes.map((a) => (a.server, a.title)).toSet(), {
      (own.url, '凡人修仙传(2020)【bilibili】'),
      (builtin.url, '凡人修仙传 外传'),
    });
    expect(DanmakuClient.sourceLabel(builtin.url), '弹弹play');
    expect(DanmakuClient.sourceLabel(own.url), isNull);
  });

  test('同名判断忽略空格、来源标记和年份', () {
    expect(sameTitleKey('凡人修仙传 (2020)【bilibili】'), sameTitleKey('凡人修仙传'));
    expect(sameTitleKey('Frieren [B站]'), sameTitleKey('frieren'));
    expect(sameTitleKey('凡人修仙传 外传'), isNot(sameTitleKey('凡人修仙传')));
  });
}
