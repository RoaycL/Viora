import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/data/media/server_registry.dart';

void main() {
  test('启动测速：限制同时测速的台数，所有结果合并成一次配置更新', () async {
    SharedPreferences.setMockInitialValues({});
    var active = 0, peak = 0;
    final fake = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => fake.close(force: true));
    fake.listen((req) async {
      // 每台服务器（路径前缀不同）同时在测的数量
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      active--;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'ServerName': 'x'}));
      await req.response.close();
    });

    ServerConfig server(int i, String url) => ServerConfig(
      id: 's$i',
      type: ServerType.emby,
      name: '服务器 $i',
      username: 'me',
      token: 'tok',
      userId: 'uid',
      lines: [ServerLine(id: 'l$i', name: '线路', url: url)],
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(configProvider.notifier);
    await store.update(
      (c) => c.copyWith(
        servers: [
          for (var i = 0; i < 5; i++) server(i, 'http://127.0.0.1:${fake.port}'),
          // 连不上的服务器：延迟清空，不影响其他台
          server(9, 'http://127.0.0.1:1').copyWith(
            lines: [const ServerLine(id: 'l9', name: '坏', url: 'http://127.0.0.1:1', latencyMs: 30)],
          ),
        ],
      ),
    );
    var updates = 0;
    container.listen(configProvider, (_, _) => updates++);

    await probeAllServers(container, concurrency: 2);

    expect(updates, 1);
    // 每台服务器一条线路，测速按顺序发 3 次：同时最多 2 台 = 最多 2 个请求
    expect(peak, lessThanOrEqualTo(2));
    final servers = container.read(configProvider).servers;
    for (final s in servers.where((s) => s.id != 's9')) {
      expect(s.lines.single.latencyMs, isNotNull, reason: s.id);
    }
    expect(servers.firstWhere((s) => s.id == 's9').lines.single.latencyMs, isNull);
  });
}
