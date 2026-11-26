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
}
