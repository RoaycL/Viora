import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config_receiver.dart';

/// 局域网里正开着「接收配置」的设备
class SyncTarget {
  const SyncTarget({required this.host, required this.port, required this.name, this.version});

  final String host;
  final int port;
  final String name;
  final String? version;

  String get address => '$host:$port';
}

/// Windows「发送到电视」：扫描局域网、推送配置
abstract final class ConfigSender {
  /// 扫描本机所在网段（/24）里开着接收入口的设备：每个地址只试默认端口，约 2–4 秒
  static Future<List<SyncTarget>> discover({Duration timeout = const Duration(milliseconds: 700)}) async {
    final own = await localAddresses();
    final hosts = <String>{
      for (final ip in own.take(3))
        for (var i = 1; i < 255; i++) '${ip.substring(0, ip.lastIndexOf('.'))}.$i',
    }..removeAll(own);
    final client = HttpClient()..connectionTimeout = timeout;
    final found = <SyncTarget>[];
    final queue = hosts.toList();
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final host = queue.removeLast();
        final t = await _ping(client, host, ConfigReceiver.ports.first, timeout);
        if (t != null) found.add(t);
      }
    }

    await Future.wait([for (var i = 0; i < 64; i++) worker()]);
    client.close(force: true);
    found.sort((a, b) => a.host.compareTo(b.host));
    return found;
  }

  static Future<SyncTarget?> _ping(HttpClient client, String host, int port, Duration timeout) async {
    try {
      final req = await client
          .getUrl(Uri(scheme: 'http', host: host, port: port, path: '/viora/ping'))
          .timeout(timeout);
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final j = jsonDecode(await res.transform(utf8.decoder).join().timeout(timeout)) as Map<String, dynamic>;
      if (j['app'] != 'viora') return null;
      return SyncTarget(host: host, port: port, name: j['name']?.toString() ?? host, version: j['version']?.toString());
    } catch (_) {
      return null;
    }
  }

  /// 解析手动输入的地址：`192.168.1.20`、`192.168.1.20:8091`、`http://192.168.1.20:8090/…`
  static Uri? parseAddress(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (!s.contains('://')) s = 'http://$s';
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty) return null;
    return Uri(scheme: 'http', host: u.host, port: u.hasPort ? u.port : ConfigReceiver.ports.first);
  }

  /// 发送配置；返回电视上的处理结果，失败时抛出带说明的异常
  static Future<String> send(Uri base, String code, Map<String, dynamic> payload) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.postUrl(base.replace(path: '/viora/import'));
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode({'code': code.trim(), 'payload': payload})));
      final res = await req.close().timeout(const Duration(seconds: 60));
      final body = await res.transform(utf8.decoder).join();
      final j = jsonDecode(body) as Map<String, dynamic>;
      if (res.statusCode != 200) throw SyncException(j['error']?.toString() ?? 'HTTP ${res.statusCode}');
      return j['message']?.toString() ?? '已发送';
    } on SocketException {
      throw const SyncException('连不上这台设备：确认它在同一个局域网，并且「接收配置」页面开着');
    } on TimeoutException {
      throw const SyncException('等待对方响应超时');
    } on FormatException {
      throw const SyncException('对方返回的内容不对，可能不是 Viora');
    } finally {
      client.close(force: true);
    }
  }
}

class SyncException implements Exception {
  const SyncException(this.message);
  final String message;

  @override
  String toString() => message;
}
