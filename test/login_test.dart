import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/media/server_registry.dart';

void main() {
  late HttpServer fake;
  final seen = <String>[];

  setUp(() async {
    seen.clear();
    // 假的 Emby：只有密码正好是 secret 时登录成功
    fake = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fake.listen((req) async {
      final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      seen.add('${req.uri.path} ${body['Pw']}');
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/emby/Users/AuthenticateByName' && body['Pw'] == 'secret') {
        req.response.write(
          jsonEncode({
            'AccessToken': 'tok',
            'User': {'Id': 'uid'},
          }),
        );
      } else {
        req.response.statusCode = 401;
      }
      await req.response.close();
    });
  });

  tearDown(() => fake.close(force: true));

  ServerConfig server(String password) => ServerConfig(
    id: 's',
    type: ServerType.emby,
    name: '内网',
    username: 'me',
    password: password,
    lines: [ServerLine(id: 'l', name: '内网', url: 'http://127.0.0.1:${fake.port}', proxied: true)],
  );

  // 配了反向代理且线路勾了「走代理」：内网地址仍然直连
  const config = AppConfig(
    deviceId: 'dev',
    proxy: ProxyConfig(baseUrl: 'https://proxy.invalid/proxy/'),
  );

  test('电视键盘在密码末尾带了空格：去掉空格重试成功，并保存去掉空格的密码', () async {
    final s = await clientForDraft(config, server('secret ')).login();
    expect(s.loggedIn, isTrue);
    expect(s.password, 'secret');
    expect(seen, ['/emby/Users/AuthenticateByName secret ', '/emby/Users/AuthenticateByName secret']);
  });

  test('密码确实不对：提示里带上被拒绝的地址', () async {
    await expectLater(
      clientForDraft(config, server('wrong')).login(),
      throwsA(
        isA<MediaServerException>().having(
          (e) => e.message,
          'message',
          allOf(contains('用户名或密码错误'), contains('127.0.0.1')),
        ),
      ),
    );
    expect(seen.length, 1, reason: '密码没有前后空格时不重试');
  });
}
