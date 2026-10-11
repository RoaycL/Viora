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
            res.write(f);
          }
        case 'PUT':
          if (!dirs.contains(parent.replaceAll(RegExp(r'/$'), ''))) {
            res.statusCode = 409;
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
}
