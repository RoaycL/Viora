import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/desktop_tray.dart';
import 'app/platform_profile.dart';
import 'app/window_frame.dart';
import 'core/log/app_log.dart';
import 'core/log/memory_watch.dart';
import 'data/config/config_store.dart';
import 'data/history/play_history.dart';
import 'data/media/server_registry.dart';
import 'data/segments/segment_http.dart';
import 'ui/widgets/cached_image.dart';

Future<void> main() async {
  final launch = Stopwatch()..start();
  WidgetsFlutterBinding.ensureInitialized();
  AppLog.install();
  // 日志实时写文件、记录内存：闪退后重新打开导出日志，能看到闪退前的情况
  if (!kIsWeb) {
    try {
      await AppLog.attachFile(await getApplicationSupportDirectory());
    } catch (_) {}
  }
  MemoryWatch.instance.start();
  if (PlatformProfile.isTv) {
    // 电视（常见 2GB 内存）：已解码图片缓存从默认 100MB / 1000 张降到 80MB / 300 张，同时最多下载 4 张图。
    // 系统内存不足时 Flutter 会自动清空这份缓存
    PaintingBinding.instance.imageCache
      ..maximumSize = 300
      ..maximumSizeBytes = 80 << 20;
    CachedNetImage.maxDownloads = 4;
  }
  MediaKit.ensureInitialized();
  await initDesktopWindow();
  await DesktopTray.instance.init();
  try {
    appVersion = (await PackageInfo.fromPlatform()).version;
    segmentClientVersion = appVersion;
  } catch (_) {}

  // 先读入本地配置（服务器、线路、代理、UA），再启动界面
  final container = ProviderContainer();
  await container.read(configProvider.notifier).load();
  await PlayHistory.load();
  final beforeUi = launch.elapsedMilliseconds;
  runApp(UncontrolledProviderScope(container: container, child: const VioraApp()));
  // 启动耗时（进入界面前 / 首帧）和本地设置文件大小：首次打开卡顿时从日志里能看出卡在哪一段
  WidgetsBinding.instance.addPostFrameCallback((_) => _logStartup(beforeUi, launch.elapsedMilliseconds));
}

Future<void> _logStartup(int beforeUi, int firstFrame) async {
  var prefs = '';
  try {
    final p = await SharedPreferences.getInstance();
    var bytes = 0;
    for (final k in p.getKeys()) {
      final v = p.get(k);
      bytes += k.length + (v is String ? v.length : 8);
    }
    prefs = ' prefs=${p.getKeys().length} keys ~${bytes ~/ 1024}KB';
  } catch (_) {}
  AppLog.add('[startup] before_ui=${beforeUi}ms first_frame=${firstFrame}ms$prefs');
}
