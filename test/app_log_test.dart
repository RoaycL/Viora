import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/core/log/app_log.dart';

void main() {
  test('日志：最多保留 3000 行，导出带版本信息', () {
    for (var i = 0; i < 3100; i++) {
      AppLog.add('line $i');
    }
    final text = AppLog.dump(appVersion: '0.13.0', extra: '服务器：Emby');
    expect(text, startsWith('Viora 0.13.0'));
    expect(text, contains('服务器：Emby'));
    expect(text, contains('line 3099'));
    expect(text, isNot(contains('line 99\n')));
    expect(text.split('\n').where((l) => l.contains(' line ')).length, AppLog.maxLines);
  });

  test('电视导出日志：只有带随机串的地址能打开，停止后连不上', () async {
    final server = LogShareServer('hello log');
    await server.start();
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<(int, String)> get(String path) async {
      final res = await (await client.get('127.0.0.1', server.port!, path)).close();
      return (res.statusCode, await res.transform(utf8.decoder).join());
    }

    expect(await get(server.path), (200, 'hello log'));
    expect((await get('/log/guess')).$1, 404);
    expect(server.path.length, greaterThan(15));
    final port = server.port!;
    await server.stop();
    // 新连接（旧连接可能还在连接池里）
    final fresh = HttpClient();
    addTearDown(() => fresh.close(force: true));
    await expectLater(fresh.get('127.0.0.1', port, server.path).then((r) => r.close()), throwsA(anything));
  });
}
