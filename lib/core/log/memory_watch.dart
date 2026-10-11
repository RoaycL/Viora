import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app_log.dart';

/// 内存记录：每 15 秒把进程内存（RSS）和图片缓存写进日志，系统发出内存不足时也记一笔。
/// 低内存电视上闪退多半是内存耗尽被系统杀掉：重新打开后导出日志，能看到闪退前内存涨到多少。
class MemoryWatch with WidgetsBindingObserver {
  static final instance = MemoryWatch();
  Timer? _timer;
  int _peakMb = 0;

  void start() {
    if (_timer != null || kIsWeb) return;
    WidgetsBinding.instance.addObserver(this);
    _sample('start');
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _sample('tick'));
  }

  void _sample(String why) {
    try {
      final rss = ProcessInfo.currentRss ~/ (1024 * 1024);
      if (rss > _peakMb) _peakMb = rss;
      final cache = PaintingBinding.instance.imageCache;
      AppLog.add(
        '[mem] $why rss=${rss}MB peak=${_peakMb}MB '
        'images=${cache.currentSize} image_mb=${(cache.currentSizeBytes / (1024 * 1024)).toStringAsFixed(1)} '
        'live=${cache.liveImageCount} pending=${cache.pendingImageCount}',
      );
    } catch (_) {}
  }

  @override
  void didHaveMemoryPressure() {
    _sample('memory-pressure');
    AppLog.flush();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => AppLog.add('[app] $state');
}
