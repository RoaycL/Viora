import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/media/server_registry.dart';

void main() {
  test('测速：免登录接口通了、用登录令牌读不到数据的线路当成不可用', () async {
    Future<HttpServer> serve({required bool authOk}) async {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      s.listen((req) async {
        final path = req.uri.path;
        if (path.endsWith('/System/Info/Public')) {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'ServerName': 'x'}));
        } else if (authOk) {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'Id': 'uid'}));
        } else {
          // 反代只放行了公开接口：其他路径回一个网页
          req.response.headers.contentType = ContentType.html;
          req.response.write('<html>login</html>');
        }
        await req.response.close();
      });
      return s;
    }

    final good = await serve(authOk: true);
    final bad = await serve(authOk: false);
    addTearDown(() => good.close(force: true));
    addTearDown(() => bad.close(force: true));
    final server = ServerConfig(
      id: 's',
      type: ServerType.emby,
      name: '服务器',
      username: 'me',
      token: 'tok',
      userId: 'uid',
      lines: [
        ServerLine(id: 'bad', name: '能 ping 通', url: 'http://127.0.0.1:${bad.port}'),
        ServerLine(id: 'good', name: '正常', url: 'http://127.0.0.1:${good.port}'),
      ],
    );
    final probed = await clientForDraft(const AppConfig(), server).probeAll(notify: false);
    expect(probed.lines.firstWhere((l) => l.id == 'bad').latencyMs, isNull);
    expect(probed.lines.firstWhere((l) => l.id == 'good').latencyMs, isNotNull);
  });

  test('测速：所有线路都读不到数据、重新登录也失败：和连不上一样当作不可用', () async {
    var logins = 0;
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => s.close(force: true));
    s.listen((req) async {
      final path = req.uri.path;
      if (path.endsWith('/System/Info/Public')) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'ServerName': 'x'}));
      } else if (path.endsWith('/Users/AuthenticateByName')) {
        logins++;
        req.response.statusCode = 401;
      } else {
        req.response.statusCode = 401;
      }
      await req.response.close();
    });
    final server = ServerConfig(
      id: 's',
      type: ServerType.emby,
      name: '服务器',
      username: 'me',
      password: 'wrong',
      token: 'expired',
      userId: 'uid',
      lines: [ServerLine(id: 'l', name: '主线路', url: 'http://127.0.0.1:${s.port}')],
    );
    final probed = await clientForDraft(const AppConfig(), server).probeAll(notify: false);
    expect(logins, greaterThan(0), reason: '先试着重新登录');
    expect(probed.lines.single.latencyMs, isNull);
  });

  test('测速：读数据超时也算不可用（红点）', () async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => s.close(force: true));
    s.listen((req) async {
      if (req.uri.path.endsWith('/System/Info/Public')) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'ServerName': 'x'}));
        await req.response.close();
      }
      // 其余请求一直不回
    });
    final server = ServerConfig(
      id: 's',
      type: ServerType.emby,
      name: '服务器',
      username: 'me',
      token: 'tok',
      userId: 'uid',
      lines: [ServerLine(id: 'l', name: '主线路', url: 'http://127.0.0.1:${s.port}')],
    );
    final probed = await clientForDraft(
      const AppConfig(),
      server,
    ).probeAll(notify: false, timeout: const Duration(milliseconds: 300));
    expect(probed.lines.single.latencyMs, isNull);
  });

  Future<ServerConfig> probeTyped(ServerType type, {required bool authOk}) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => s.close(force: true));
    s.listen((req) async {
      final path = req.uri.path;
      req.response.headers.contentType = ContentType.json;
      if (path.endsWith('/identity') || path == '/v' || path == '/v/') {
        req.response.write(jsonEncode({'MediaContainer': {}}));
      } else if (path.endsWith('/library/sections')) {
        if (authOk) {
          req.response.write(
            jsonEncode({
              'MediaContainer': {'Directory': []},
            }),
          );
        } else {
          req.response.statusCode = 401;
        }
      } else if (path.endsWith('/user/info')) {
        req.response.write(jsonEncode(authOk ? {'code': 0, 'data': {}} : {'code': -2, 'msg': 'Auth Failed'}));
      } else {
        req.response.statusCode = 401;
      }
      await req.response.close();
    });
    final server = ServerConfig(
      id: 's',
      type: type,
      name: '服务器',
      username: 'me',
      token: 'tok',
      userId: 'uid',
      lines: [ServerLine(id: 'l', name: '主线路', url: 'http://127.0.0.1:${s.port}')],
    );
    return clientForDraft(const AppConfig(), server).probeAll(notify: false, timeout: const Duration(seconds: 2));
  }

  for (final type in [ServerType.plex, ServerType.fnos]) {
    test('测速：${type.name} 也用登录令牌验证线路', () async {
      expect((await probeTyped(type, authOk: true)).lines.single.latencyMs, isNotNull);
      expect((await probeTyped(type, authOk: false)).lines.single.latencyMs, isNull);
    });
  }
}
