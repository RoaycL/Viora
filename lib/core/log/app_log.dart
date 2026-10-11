import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// 应用日志：保存最近 3000 行（debugPrint、Flutter 错误、未捕获异常），出问题时导出发给开发者。
/// 不记录密码、令牌（代码里不会把它们打印出来）。
abstract final class AppLog {
  static const maxLines = 3000;
  static final _lines = ListQueue<String>();
  static bool _installed = false;

  static void add(String message) {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
    for (final line in message.split('\n')) {
      _lines.add('$stamp $line');
    }
    while (_lines.length > maxLines) {
      _lines.removeFirst();
    }
  }

  static void install() {
    if (_installed) return;
    _installed = true;
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) add(message);
      original(message, wrapWidth: wrapWidth);
    };
    final flutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      add('FlutterError: ${details.exceptionAsString()}\n${details.stack ?? ''}');
      flutterError?.call(details);
    };
    final platformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      add('Uncaught: $error\n$stack');
      return platformError?.call(error, stack) ?? false;
    };
  }

  /// 导出的全文：开头是版本、系统信息
  static String dump({required String appVersion, String extra = ''}) {
    final header = [
      'Viora $appVersion',
      if (!kIsWeb) '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      '导出时间 ${DateTime.now()}',
      if (extra.isNotEmpty) extra,
      '─' * 40,
    ];
    return [...header, ..._lines].join('\n');
  }
}

/// 电视上导出日志：临时开一个局域网地址，手机扫码直接在浏览器里看 / 保存（5 分钟后自动关闭）
class LogShareServer {
  LogShareServer(this.text);

  final String text;
  HttpServer? _server;
  Timer? _timer;

  /// 路径里带随机串，别人猜不到
  final path = '/log/${List.generate(12, (_) => Random.secure().nextInt(36).toRadixString(36)).join()}';
  int? get port => _server?.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _timer = Timer(const Duration(minutes: 5), stop);
    _server!.listen((req) async {
      if (req.uri.path == path) {
        req.response.headers
          ..contentType = ContentType('text', 'plain', charset: 'utf-8')
          ..set('Content-Disposition', 'inline; filename="viora-log.txt"');
        req.response.write(text);
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    await _server?.close(force: true);
    _server = null;
  }
}
