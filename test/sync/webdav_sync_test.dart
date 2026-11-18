import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/data/sync/webdav_sync.dart';
import 'package:viora/features/sync/webdav_service.dart';

/// 内存里的 WebDAV：PROPFIND / MKCOL / GET / PUT，带 Basic 认证
class _FakeDav {
  late HttpServer server;
  final files = <String, String>{};
  final dirs = <String>{'/dav'};
  int puts = 0;
  final createConditions = <String?>[];
  bool sendEtag = true;
  bool sendWeakEtag = false;
  Future<void> Function()? beforePut;
  void Function()? afterGet;

  String etag(String content) => '"${base64.encode(utf8.encode(content))}"';

  /// 父目录不存在时回的状态码（有的服务器回 405 而不是 409）
  int missingParent = 409;

  /// 只读：PUT 一律 405
  bool readOnly = false;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final auth = req.headers.value('authorization');
      final res = req.response;
      if (auth != 'Basic ${base64.encode(utf8.encode('me:pw'))}') {
        res.statusCode = 401;
        return res.close();
      }
      final path = Uri.decodeComponent(req.uri.path);
      final parent = path.endsWith('/') ? path : path.substring(0, path.lastIndexOf('/'));
      switch (req.method) {
        case 'PROPFIND':
          res.statusCode = dirs.contains(path.replaceAll(RegExp(r'/$'), '')) ? 207 : 404;
        case 'MKCOL':
          final dir = path.replaceAll(RegExp(r'/$'), '');
          res.statusCode = dirs.add(dir) ? 201 : 405;
        case 'GET':
          final f = files[path];
          if (f == null) {
            res.statusCode = 404;
          } else {
            if (sendEtag) res.headers.set('etag', '${sendWeakEtag ? 'W/' : ''}${etag(f)}');
            res.write(f);
            final hook = afterGet;
            afterGet = null;
            hook?.call();
          }
        case 'PUT':
          createConditions.add(req.headers.value('if-none-match'));
          final hook = beforePut;
          beforePut = null;
          await hook?.call();
          final current = files[path];
          final match = req.headers.value('if-match');
          final createOnly = req.headers.value('if-none-match') == '*';
          if ((createOnly && current != null) || (match != null && (current == null || match != etag(current)))) {
            await req.drain<void>();
            res.statusCode = 412;
          } else if (readOnly) {
            res.statusCode = 405;
          } else if (!dirs.contains(parent.replaceAll(RegExp(r'/$'), ''))) {
            res.statusCode = missingParent;
          } else {
            files[path] = await utf8.decodeStream(req);
            puts++;
            res.statusCode = 201;
          }
        default:
          res.statusCode = 405;
      }
      await res.close();
    });
  }

  String get url => 'http://127.0.0.1:${server.port}/dav/';
}

ServerConfig _server(String id, String host) => ServerConfig(
  id: id,
  type: ServerType.emby,
  name: host,
  lines: [ServerLine(id: 'l$id', name: '主线路', url: 'http://127.0.0.1:1/$host')],
  username: 'u',
  password: 'p-$host',
);

void main() {
  late _FakeDav dav;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ConfigStore.vault = MemoryVault();
    dav = _FakeDav();
    await dav.start();
  });
  tearDown(() => dav.server.close(force: true));

  Future<(ProviderContainer, WebDavSync)> device(String name, AppConfig config) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(configProvider.notifier).update((_) => config);
    final sync = WebDavSync(c, stateKey: 'state.$name');
    addTearDown(sync.dispose);
    return (c, sync);
  }

  List<String> names(ProviderContainer c) => [for (final s in c.read(configProvider).allServers) s.name]..sort();

  test('两台设备通过 WebDAV 同步：新增、合并、删除都能同步，云端文件加密', () async {
    final webdav = WebDavConfig(url: dav.url, username: 'me', password: 'pw', passphrase: '口令');
    final (a, syncA) = await device('a', AppConfig(servers: [_server('1', 'home')], webdav: webdav, deviceId: 'A'));
    final (b, syncB) = await device('b', AppConfig(servers: [_server('2', 'friend')], webdav: webdav, deviceId: 'B'));

    // A 第一次同步：云端没有文件 → 上传（目录自动创建）
    expect(await syncA.sync(), contains('已上传'));
    final file = dav.files['/dav/Viora/viora-config.json']!;
    expect(file, isNot(contains('p-home')), reason: '设置了口令，密码不能明文出现在云端');
    expect(jsonDecode(file)['encrypted'], isNotNull);

    // B 第一次同步：两边都有内容 → 合并后上传，谁的服务器都不丢
    expect(await syncB.sync(), contains('合并'));
    expect(names(b), ['friend', 'home']);

    // A：云端变了、本机没改 → 下载
    expect(await syncA.sync(), contains('下载'));
    expect(names(a), ['friend', 'home']);
    expect(a.read(configProvider).allServers.firstWhere((s) => s.name == 'friend').password, 'p-friend');

    // 再同步一次：两边都没变
    final puts = dav.puts;
    expect(await syncA.sync(), '已是最新');
    expect(dav.puts, puts);

    // A 删掉 friend → 上传；B 下载后也删掉（删除能同步）
    await a
        .read(configProvider.notifier)
        .update((c) => c.copyWith(servers: [...c.allServers.where((s) => s.name == 'home')]));
    expect(await syncA.sync(), contains('上传本机的修改'));
    expect(await syncB.sync(), contains('删除服务器 1 台'));
    expect(names(b), ['home']);
  });

  test('同时创建云端文件：失败的一方重读合并，不丢服务器', () async {
    final webdav = WebDavConfig(url: dav.url, username: 'me', password: 'pw');
    final (a, syncA) = await device('a', AppConfig(servers: [_server('1', 'home')], webdav: webdav));
    final (_, syncB) = await device('b', AppConfig(servers: [_server('2', 'friend')], webdav: webdav));
    dav.beforePut = () async {
      await syncB.sync();
    };
    expect(await syncA.sync(), contains('合并'));
    expect(names(a), ['friend', 'home']);
    final remote = jsonDecode(dav.files['/dav/Viora/viora-config.json']!) as Map;
    expect((remote['servers'] as List).map((s) => s['name']), containsAll(['friend', 'home']));
  });

  test('读取后发生远端修改：条件写入冲突后重新合并', () async {
    final webdav = WebDavConfig(url: dav.url, username: 'me', password: 'pw');
    final (a, syncA) = await device('a', AppConfig(servers: [_server('1', 'home')], webdav: webdav));
    await syncA.sync();
    final (b, syncB) = await device('b', AppConfig(webdav: webdav));
    await syncB.sync();
    await syncA.sync();
    await a.read(configProvider.notifier).upsertServer(_server('3', 'local'));
    await b.read(configProvider.notifier).upsertServer(_server('2', 'friend'));
    dav.beforePut = () async {
      await syncB.sync();
    };
    expect(await syncA.sync(), contains('合并'));
    expect(names(a), ['friend', 'home', 'local']);
    final remote = jsonDecode(dav.files['/dav/Viora/viora-config.json']!) as Map;
    expect((remote['servers'] as List).map((s) => s['name']), containsAll(['friend', 'home', 'local']));
  });

  test('没有强 ETag 时自动上传仍可用：上传前重新确认云端没被改过', () async {
    final webdav = WebDavConfig(url: dav.url, username: 'me', password: 'pw');
    final (a, syncA) = await device('a', AppConfig(servers: [_server('1', 'home')], webdav: webdav));
    await syncA.sync();
    var n = 1;
    for (final weak in [false, true]) {
      dav.sendEtag = weak;
      dav.sendWeakEtag = weak;
      await a.read(configProvider.notifier).upsertServer(_server('${++n}', 'friend$n'));
      expect(await syncA.sync(), contains('上传'));
      final remote = jsonDecode(dav.files['/dav/Viora/viora-config.json']!) as Map;
      expect((remote['servers'] as List).map((s) => s['name']), contains('friend$n'));
    }
    expect(await syncA.sync(mode: WebDavSyncMode.upload), contains('覆盖云端'));
  });

  test('没有 ETag 时：读取后云端被别的设备改过，按冲突重新合并，不覆盖对方的修改', () async {
    final webdav = WebDavConfig(url: dav.url, username: 'me', password: 'pw');
    final (a, syncA) = await device('a', AppConfig(servers: [_server('1', 'home')], webdav: webdav));
    await syncA.sync();
    dav.sendEtag = false;
    await a.read(configProvider.notifier).upsertServer(_server('2', 'local'));
    dav.afterGet = () {
      final remote = jsonDecode(dav.files['/dav/Viora/viora-config.json']!) as Map<String, dynamic>;
      remote['rev'] = 'other-device';
      remote['servers'] = [
        ...remote['servers'] as List,
        {
          'type': 'emby',
          'name': 'other',
          'lines': [
            {'name': '主线路', 'url': 'http://127.0.0.1:1/other', 'proxied': false},
          ],
          'username': 'u',
          'password': 'p-other',
        },
      ];
      dav.files['/dav/Viora/viora-config.json'] = jsonEncode(remote);
    };
    expect(await syncA.sync(), contains('合并'));
    final remote = jsonDecode(dav.files['/dav/Viora/viora-config.json']!) as Map;
    expect((remote['servers'] as List).map((s) => s['name']), containsAll(['home', 'local', 'other']));
  });

  test('连续冲突最多重试三次，不覆盖云端的新版本', () async {
    final webdav = WebDavConfig(url: dav.url, username: 'me', password: 'pw');
    final (a, syncA) = await device('a', AppConfig(servers: [_server('1', 'home')], webdav: webdav));
    await syncA.sync();
    await a.read(configProvider.notifier).upsertServer(_server('2', 'local'));
    var conflicts = 0;
    Future<void> changeRemote() async {
      conflicts++;
      final remote = jsonDecode(dav.files['/dav/Viora/viora-config.json']!) as Map<String, dynamic>;
      remote['rev'] = 'other-device-$conflicts';
      dav.files['/dav/Viora/viora-config.json'] = jsonEncode(remote);
      dav.beforePut = changeRemote;
    }

    dav.beforePut = changeRemote;
    await expectLater(syncA.sync(), throwsA(isA<WebDavConflict>()));
    expect(conflicts, 3);
    final remote = jsonDecode(dav.files['/dav/Viora/viora-config.json']!) as Map;
    expect(remote['rev'], 'other-device-3');
    expect((remote['servers'] as List).length, 1);
    expect(names(a), ['home', 'local']);
  });

  test('创建目录后的 PUT 重试仍携带首次创建条件', () async {
    final client = WebDavClient(WebDavConfig(url: dav.url, username: 'me', password: 'pw'));
    await client.write('{"viora":1}', ifNoneMatch: true);
    expect(dav.createConditions, ['*', '*']);
    await expectLater(client.write('{"viora":2}', ifNoneMatch: true), throwsA(isA<WebDavConflict>()));
    expect(dav.files['/dav/Viora/viora-config.json'], '{"viora":1}');
  });

  test('口令不对、账号不对时给出原因', () async {
    final good = WebDavConfig(url: dav.url, username: 'me', password: 'pw', passphrase: 'right');
    final (_, syncA) = await device('a', AppConfig(servers: [_server('1', 'home')], webdav: good));
    await syncA.sync();

    final (_, syncC) = await device('c', AppConfig(webdav: good.copyWith(passphrase: 'wrong')));
    await expectLater(
      syncC.sync(),
      throwsA(isA<WebDavException>().having((e) => e.message, 'message', contains('口令不对'))),
    );

    await expectLater(
      WebDavClient(good.copyWith(password: 'bad')).test(),
      throwsA(isA<WebDavException>().having((e) => e.message, 'message', contains('用户名或密码错误'))),
    );
    await WebDavClient(good).test();
  });

  test('密码和加密口令存进密钥库，配置文件里没有明文', () async {
    final vault = MemoryVault();
    ConfigStore.vault = vault;
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c
        .read(configProvider.notifier)
        .update(
          (x) => x.copyWith(
            webdav: const WebDavConfig(url: 'https://dav.example.com/', password: 'pw', passphrase: 'pp'),
          ),
        );
    final raw = (await SharedPreferences.getInstance()).getString('viora.config.v1')!;
    expect(raw, isNot(contains('"pw"')));
    expect(raw, isNot(contains('"pp"')));

    final reloaded = ProviderContainer();
    addTearDown(reloaded.dispose);
    await reloaded.read(configProvider.notifier).load();
    expect(reloaded.read(configProvider).webdav.password, 'pw');
    expect(reloaded.read(configProvider).webdav.passphrase, 'pp');
  });

  test('父目录不存在时回 405 的服务器：建好目录后重试成功；只读目录给出明确原因', () async {
    dav.missingParent = 405;
    const base = WebDavConfig(username: 'me', password: 'pw');
    final client = WebDavClient(base.copyWith(url: dav.url));
    await client.write('{"viora":1}');
    expect(dav.files['/dav/Viora/viora-config.json'], '{"viora":1}');

    dav.readOnly = true;
    await expectLater(
      client.write('{"viora":1}'),
      throwsA(isA<WebDavException>().having((e) => e.message, 'message', contains('只读'))),
    );
  });

  test('关闭 WebDAV 同步后不再同步，设置保留；重新打开后照常同步', () async {
    final webdav = WebDavConfig(url: dav.url, username: 'me', password: 'pw');
    final (a, syncA) = await device('a', AppConfig(servers: [_server('1', 'home')], webdav: webdav));
    await a.read(configProvider.notifier).update((c) => c.copyWith(webdav: c.webdav.copyWith(enabled: false)));
    await expectLater(
      syncA.sync(),
      throwsA(isA<WebDavException>().having((e) => e.message, 'message', contains('已关闭'))),
    );
    expect(dav.puts, 0);
    expect(a.read(configProvider).webdav.url, dav.url);
    expect(WebDavConfig.fromJson(a.read(configProvider).webdav.toJson()).enabled, isFalse);

    await a.read(configProvider.notifier).update((c) => c.copyWith(webdav: c.webdav.copyWith(enabled: true)));
    expect(await syncA.sync(), contains('已上传'));
    expect(dav.puts, 1);
    // 旧配置没有这个字段：默认打开
    expect(WebDavConfig.fromJson(const {'url': 'https://x'}).active, isTrue);
  });
}
