import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/core/net/error_text.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/media/media_models.dart';

/// 本机假服务器：按路径返回状态码和 JSON，记下收到的请求
class _Fake {
  _Fake(this.http);
  final HttpServer http;
  final paths = <String>[];
  int Function(Uri uri) status = (_) => 200;
  Object Function(Uri uri) body = (_) => const {};

  static Future<_Fake> start() async {
    final f = _Fake(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    f.http.listen((request) async {
      // Emby 的接口路径带 /emby 前缀，去掉后再匹配
      final uri = request.uri.replace(path: request.uri.path.replaceFirst(RegExp('^/emby'), ''));
      f.paths.add(uri.path);
      request.response.statusCode = f.status(uri);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(f.body(uri)));
      await request.response.close();
    });
    return f;
  }

  String get url => 'http://127.0.0.1:${http.port}';
}

EmbyClient _client(List<ServerLine> lines) {
  final server = ServerConfig(
    id: 's',
    type: ServerType.emby,
    name: 'home',
    username: 'alice',
    userId: 'u1',
    token: 'token',
    lines: lines,
  );
  return EmbyClient(config: AppConfig(servers: [server]), server: server, appVersion: 'test');
}

void main() {
  test('单条详情接口报 502 时改用列表接口按 ID 取，页面照常打开', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.status = (uri) => uri.path == '/Users/u1/Items/x1' ? 502 : 200;
    fake.body = (uri) => uri.path == '/Users/u1/Items' && uri.queryParameters['Ids'] == 'x1'
        ? {
            'Items': [
              {'Id': 'x1', 'Type': 'Series', 'Name': '蚝油的鲜味传奇', 'ProductionYear': 2026},
            ],
            'TotalRecordCount': 1,
          }
        : const {};
    final item = await _client([ServerLine(id: 'l', name: 'main', url: fake.url)]).item('x1');
    expect(item.id, 'x1');
    expect(item.kind, MediaKind.series);
    expect(item.name, '蚝油的鲜味传奇');
    expect(fake.paths, ['/Users/u1/Items/x1', '/Users/u1/Items']);
  });

  test('列表接口也找不到时报中文说明，不显示 Dio 的英文原文', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.status = (uri) => uri.path == '/Users/u1/Items/x1' ? 502 : 200;
    fake.body = (_) => {'Items': [], 'TotalRecordCount': 0};
    final error = await _client([ServerLine(id: 'l', name: 'main', url: fake.url)])
        .item('x1')
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(error, isA<MediaServerException>());
    expect((error! as MediaServerException).statusCode, 502);
    expect('$error', contains('HTTP 502'));
    expect('$error', isNot(contains('RequestOptions')));
  });

  test('404 等客户端错误不走列表接口', () async {
    final fake = await _Fake.start();
    addTearDown(() => fake.http.close(force: true));
    fake.status = (_) => 404;
    await expectLater(
      _client([ServerLine(id: 'l', name: 'main', url: fake.url)]).item('x1'),
      throwsA(isA<MediaServerException>()),
    );
    expect(fake.paths, ['/Users/u1/Items/x1']);
  });

  test('一条线路的反代报 502 时换下一条线路', () async {
    final bad = await _Fake.start();
    final good = await _Fake.start();
    addTearDown(() => bad.http.close(force: true));
    addTearDown(() => good.http.close(force: true));
    bad.status = (_) => 502;
    good.body = (_) => {'Id': 'x1', 'Type': 'Movie', 'Name': 'ok'};
    final item = await _client([
      ServerLine(id: 'a', name: 'proxy', url: bad.url),
      ServerLine(id: 'b', name: 'direct', url: good.url),
    ]).item('x1');
    expect(item.name, 'ok');
    expect(bad.paths, ['/Users/u1/Items/x1']);
    expect(good.paths, ['/Users/u1/Items/x1']);
  });

  test('界面错误说明：Dio 错误换成中文短句', () {
    final options = RequestOptions(path: '/x');
    DioException bad(int status) => DioException.badResponse(
      statusCode: status,
      requestOptions: options,
      response: Response<void>(requestOptions: options, statusCode: status),
    );
    expect(errorText(bad(502)), '服务暂时无法响应（HTTP 502），稍后重试');
    expect(errorText(bad(404)), contains('404'));
    expect(errorText(DioException.connectionTimeout(timeout: Duration.zero, requestOptions: options)), '连接超时，请检查网络');
    expect(errorText(const MediaServerException('登录已失效')), '登录已失效');
  });
}
