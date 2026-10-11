import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// 应用日志：保存最近 3000 行（debugPrint、Flutter 错误、未捕获异常），出问题时导出发给开发者。
/// 不记录密码、令牌（代码里不会把它们打印出来）。
///
/// 同时实时写进文件（[attachFile]）：闪退时内存里的日志会丢，重新打开后导出能看到上次运行到哪里、内存涨到多少。
abstract final class AppLog {
  static const maxLines = 3000;
  static final _lines = ListQueue<String>();
  static bool _installed = false;

  /// 本次运行的日志文件；上次运行的日志改名为 [_previousName]
  static IOSink? _sink;
  static Timer? _flushTimer;
  static String _previous = '';
  static const _currentName = 'viora-run.log';
  static const _previousName = 'viora-run.prev.log';

  /// 单个文件最多写这么多，避免长时间运行写满存储
  static const _maxFileBytes = 4 * 1024 * 1024;
  static int _written = 0;

  static void add(String message) {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
    for (final line in message.split('\n')) {
      final entry = '$stamp $line';
      _lines.add(entry);
      final sink = _sink;
      if (sink != null && _written < _maxFileBytes) {
        sink.writeln(entry);
        _written += entry.length + 1;
      }
    }
    while (_lines.length > maxLines) {
      _lines.removeFirst();
    }
  }

  /// 打开日志文件（应用数据目录）。上次运行的日志保留一份，导出时附在后面
  static Future<void> attachFile(Directory dir) async {
    if (_sink != null) return;
    try {
      final current = File('${dir.path}${Platform.pathSeparator}$_currentName');
      final previous = File('${dir.path}${Platform.pathSeparator}$_previousName');
      if (await current.exists()) {
        if (await previous.exists()) await previous.delete();
        await current.rename(previous.path);
      }
      if (await previous.exists()) {
        final text = await previous.readAsString();
        // 只保留结尾部分：闪退前发生的事在最后
        _previous = text.length > 200000 ? text.substring(text.length - 200000) : text;
      }
      final sink = current.openWrite();
      _sink = sink;
      for (final line in _lines) {
        sink.writeln(line);
      }
      // 每秒落盘一次：闪退时最多丢最后一秒
      _flushTimer = Timer.periodic(const Duration(seconds: 1), (_) => flush());
    } catch (e) {
      debugPrint('log file unavailable: $e');
    }
  }

  /// 立即写入磁盘（出错时调用）
  static void flush() {
    final sink = _sink;
    if (sink == null) return;
    unawaited(sink.flush().catchError((Object _) {}));
  }

  @visibleForTesting
  static Future<void> detachFileForTesting() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    _written = 0;
    _previous = '';
    _lines.clear();
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
      flush();
      flutterError?.call(details);
    };
    final platformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      add('Uncaught: $error\n$stack');
      flush();
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
    return [
      ...header,
      ..._lines,
      if (_previous.isNotEmpty) ...['', '─' * 40, '上次运行的日志（如果上次是闪退，最后几行就是闪退前的情况）', '─' * 40, _previous],
    ].join('\n');
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
