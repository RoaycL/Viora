import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/sync/config_payload.dart';
import 'package:viora/data/sync/config_receiver.dart';
import 'package:viora/data/sync/config_sender.dart';
import 'package:viora/domain/models/segment_settings.dart';

void main() {
  const existing = ServerConfig(
    id: 'a',
    type: ServerType.emby,
    name: '家里',
    lines: [ServerLine(id: 'l1', name: '主线路', url: 'https://emby.home.com/')],
    username: 'me',
    password: 'old',
    userId: 'u',
    token: 't',
  );
  const base = AppConfig(
    servers: [existing],
    tmdb: TmdbConfig(apiKey: 'k0', baseUrl: 'https://tmdb.proxy'),
  );

  group('mergeSyncPayload', () {
    test('同一台服务器更新（改了密码要重新登录），新服务器新增', () {
      final r = mergeSyncPayload(base, {
        'viora': 1,
        'servers': [
          {
            'type': 'emby',
            'name': '',
            'lines': [
              {'name': '主线路', 'url': 'https://EMBY.home.com', 'proxied': true},
              {'name': '', 'url': 'http://192.168.1.2:8096'},
            ],
            'username': 'me',
            'password': 'new',
          },
          {
            'type': 'jellyfin',
            'lines': [
              {'url': 'https://jf.example.com'},
            ],
            'username': 'kid',
            'password': '',
          },
          {'type': 'emby', 'lines': <Object>[], 'username': 'x'},
        ],
      });
      expect(r.summary, ['新增服务器 1 台', '更新服务器 1 台']);
      expect(r.config.servers.length, 2);
      final a = r.config.server('a')!;
      expect(a.name, '家里');
      expect(a.lines.length, 2);
      expect(a.lines[0].proxied, isTrue);
      expect(a.lines[1].name, '线路 2');
      expect(a.password, 'new');
      expect(a.token, isNull, reason: '密码变了，旧令牌作废');
      final jf = r.config.servers.last;
      expect(jf.type, ServerType.jellyfin);
      expect(jf.loggedIn, isFalse);
      expect(r.changedServerIds, containsAll(['a', jf.id]));
    });

    test('密码没变时保留登录状态', () {
      final r = mergeSyncPayload(base, {
        'viora': 1,
        'servers': [
          {
            'type': 'emby',
            'lines': [
              {'url': 'https://emby.home.com'},
            ],
            'username': 'me',
            'password': 'old',
          },
        ],
      });
      expect(r.config.server('a')!.token, 't');
    });

    test('其他部分只覆盖带过来的字段', () {
      final r = mergeSyncPayload(base, {
        'viora': 1,
        'tmdb': {'apiKey': 'k1'},
        'danmaku': {
          'servers': ['https://d.example.com/t'],
        },
        'proxy': {'baseUrl': 'https://p.example.com/proxy/'},
      });
      expect(r.config.tmdb.apiKey, 'k1');
      expect(r.config.tmdb.baseUrl, 'https://tmdb.proxy');
      expect(r.config.danmaku.servers, ['https://d.example.com/t']);
      expect(r.config.danmaku.maxCount, 3000);
      expect(r.config.proxy.baseUrl, 'https://p.example.com/proxy/');
      expect(r.config.servers.single.id, 'a');
    });

    test('片头片尾 Key：填了的数据源同时打开，其他保留本机设置', () {
      final r = mergeSyncPayload(base, {
        'viora': 1,
        'segments': {
          'keys': {'publicmetadb': 'pk'},
        },
      });
      final current = SegmentSettings.defaults();
      final next = applySegmentSync(current, r);
      final p = next.providers.firstWhere((p) => p.id == 'publicmetadb');
      expect(p.apiKey, 'pk');
      expect(p.enabled, isTrue);
    });

    test('Windows 打包后再合并：内容一致，不带令牌', () {
      final payload = buildSyncPayload(base, sections: {SyncSection.servers, SyncSection.tmdb}, from: 'Windows');
      expect(jsonEncode(payload), isNot(contains('"token"')));
      expect(payload.containsKey('danmaku'), isFalse);
      final r = mergeSyncPayload(const AppConfig(), payload);
      expect(r.config.servers.single.lines.single.url, 'https://emby.home.com/');
      expect(r.config.servers.single.password, 'old');
      expect(r.config.tmdb.apiKey, 'k0');
    });

    test('不是 Viora 的内容', () {
      expect(() => mergeSyncPayload(base, {'servers': <Object>[]}), throwsFormatException);
      expect(mergeSyncPayload(base, {'viora': 1}).isEmpty, isTrue);
    });
  });

  test('接收端 + 发送端：发现、配对码校验、网页、导入', () async {
    Map<String, dynamic>? got;
    final r = ConfigReceiver(
      deviceName: 'Viora · 测试电视',
      appVersion: '0.11.2',
      onPayload: (p, from) async {
        got = p;
        return '已导入：TMDB';
      },
    );
    await r.start();
    addTearDown(r.dispose);
    expect(r.port, isNotNull);
    final uri = Uri(scheme: 'http', host: '127.0.0.1', port: r.port);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final ping = await (await client.getUrl(uri.replace(path: '/viora/ping'))).close();
    expect(jsonDecode(await ping.transform(utf8.decoder).join())['name'], 'Viora · 测试电视');
    final page = await (await client.getUrl(uri)).close();
    expect(await page.transform(utf8.decoder).join(), contains('导入配置到 Viora · 测试电视'));

    final wrong = r.code == '1234' ? '4321' : '1234';
    await expectLater(
      ConfigSender.send(uri, wrong, {'viora': 1}),
      throwsA(isA<SyncException>().having((e) => e.message, 'message', contains('配对码不对'))),
    );
    expect(got, isNull);

    final message = await ConfigSender.send(uri, r.code, {
      'viora': 1,
      'tmdb': {'apiKey': 'x'},
    });
    expect(message, '已导入：TMDB');
    expect(got?['tmdb'], {'apiKey': 'x'});

    // 连续输错 5 次换新码
    final old = r.code;
    for (var i = 0; i < 5; i++) {
      try {
        await ConfigSender.send(uri, old == '0000' ? '1111' : '0000', {'viora': 1});
      } on SyncException catch (_) {}
    }
    expect(r.code, isNot(old));

    await r.stop();
    await expectLater(ConfigSender.send(uri, r.code, {'viora': 1}), throwsA(isA<SyncException>()));
  });

  test('手动输入的地址', () {
    expect(ConfigSender.parseAddress('192.168.1.20').toString(), 'http://192.168.1.20:8090');
    expect(ConfigSender.parseAddress('192.168.1.20:8091').toString(), 'http://192.168.1.20:8091');
    expect(ConfigSender.parseAddress('http://192.168.1.20:8092/?code=1').toString(), 'http://192.168.1.20:8092');
    expect(ConfigSender.parseAddress(' '), isNull);
  });
}
