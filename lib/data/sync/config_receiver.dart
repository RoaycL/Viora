import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'sync_web_page.dart';

/// 局域网里临时开的配置接收入口（docs/11-sync.md）。
///
/// - 只在「接收配置」窗口打开期间监听，关闭窗口、导入后 5 分钟没有操作都会自动关闭；
/// - 每次随机 4 位配对码，连续输错 5 次换一个新码；
/// - `GET /` 手机配置网页，`GET /viora/ping` 供 Windows 端扫描发现，`POST /viora/import` 接收配置。
class ConfigReceiver {
  ConfigReceiver({required this.deviceName, required this.appVersion, required this.onPayload});

  /// 默认端口；被占用时依次尝试后面几个（Windows 端扫描时也按这几个找）
  static const ports = [8090, 8091, 8092, 8093];
  static const idleTimeout = Duration(minutes: 5);
  static const maxBodyBytes = 512 * 1024;

  final String deviceName;
  final String appVersion;

  /// 收到配对码正确的配置；返回给发送方看的结果说明
  final Future<String> Function(Map<String, dynamic> payload, String from) onPayload;

  /// 状态变化（配对码更换、超时关闭等），界面据此刷新
  final changes = ValueNotifier(0);

  HttpServer? _server;
  Timer? _idle;
  int _failures = 0;
  final _random = Random.secure();

  late String code = _newCode();
  int? port;
  List<String> addresses = const [];
  bool closedByTimeout = false;

  bool get running => _server != null;

  /// 二维码 / 手机浏览器打开的地址（带配对码，扫码后不用再输）
  String? get url => addresses.isEmpty || port == null ? null : 'http://${addresses.first}:$port/?code=$code';

  String _newCode() => (1000 + _random.nextInt(9000)).toString();

  Future<void> start() async {
    addresses = await localAddresses();
    for (final p in ports) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, p, shared: false);
        port = p;
        break;
      } on SocketException {
        continue;
      }
    }
    final server = _server;
    if (server == null) throw const SocketException('端口 8090–8093 都被占用');
    _touch();
    server.listen(_handle, onError: (Object e) => debugPrint('sync receiver: $e'));
    if (!_disposed) changes.value++;
  }

  Future<void> stop() async {
    _idle?.cancel();
    final s = _server;
    _server = null;
    await s?.close(force: true);
    if (!_disposed) changes.value++;
  }

  bool _disposed = false;

  void dispose() {
    _disposed = true;
    stop();
    changes.dispose();
  }

  void _touch() {
    _idle?.cancel();
    _idle = Timer(idleTimeout, () {
      closedByTimeout = true;
      stop();
    });
  }

  Future<void> _handle(HttpRequest req) async {
    _touch();
    final res = req.response;
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && (path == '/' || path == '/index.html')) {
        res.headers.contentType = ContentType.html;
        res.write(syncWebPage(deviceName: deviceName));
      } else if (req.method == 'GET' && path == '/viora/ping') {
        _json(res, 200, {'app': 'viora', 'name': deviceName, 'version': appVersion});
      } else if (req.method == 'POST' && path == '/viora/import') {
        await _import(req, res);
      } else {
        _json(res, 404, {'error': '没有这个地址'});
      }
    } catch (e) {
      _json(res, 500, {'error': '$e'});
    } finally {
      await res.close();
    }
  }

  Future<void> _import(HttpRequest req, HttpResponse res) async {
    final bytes = <int>[];
    await for (final chunk in req) {
      bytes.addAll(chunk);
      if (bytes.length > maxBodyBytes) {
        _json(res, 413, {'error': '内容太大'});
        return;
      }
    }
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      _json(res, 400, {'error': '格式不对'});
      return;
    }
    if (body['code']?.toString().trim() != code) {
      _failures++;
      if (_failures >= 5) {
        _failures = 0;
        code = _newCode();
        if (!_disposed) changes.value++;
        _json(res, 403, {'error': '配对码连续输错，电视上已经换了新的配对码'});
      } else {
        _json(res, 403, {'error': '配对码不对，请看电视屏幕上的 4 位数字'});
      }
      return;
    }
    _failures = 0;
    final payload = body['payload'];
    if (payload is! Map<String, dynamic>) {
      _json(res, 400, {'error': '没有配置内容'});
      return;
    }
    try {
      final message = await onPayload(payload, payload['from']?.toString() ?? '');
      _json(res, 200, {'ok': true, 'message': message});
    } on FormatException catch (e) {
      _json(res, 400, {'error': e.message});
    }
  }

  static void _json(HttpResponse res, int status, Map<String, Object?> body) {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
  }
}

/// 本机的局域网 IPv4 地址（家用网段优先，Wi-Fi / 有线网卡优先）
Future<List<String>> localAddresses() async {
  try {
    final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
    final candidates = <(int, String)>[];
    for (final nic in list) {
      final name = nic.name.toLowerCase();
      // 虚拟网卡（Docker、虚拟机、VPN）排后面
      final virtual = RegExp(r'docker|veth|vmnet|virtual|vbox|hyper|tun|tap|wsl|vpn|zt|tailscale').hasMatch(name);
      for (final a in nic.addresses) {
        final ip = a.address;
        if (a.isLoopback || ip.startsWith('169.254.')) continue;
        final private =
            ip.startsWith('192.168.') || ip.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);
        if (!private) continue;
        candidates.add(((virtual ? 2 : 0) + (ip.startsWith('192.168.') ? 0 : 1), ip));
      }
    }
    candidates.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final c in candidates) c.$2];
  } catch (_) {
    return const [];
  }
}
