import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app/app.dart';
import 'app/window_frame.dart';
import 'core/log/app_log.dart';
import 'data/config/config_store.dart';
import 'data/history/play_history.dart';
import 'data/media/server_registry.dart';
import 'data/segments/segment_http.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLog.install();
  MediaKit.ensureInitialized();
  await initDesktopWindow();
  try {
    appVersion = (await PackageInfo.fromPlatform()).version;
    segmentClientVersion = appVersion;
  } catch (_) {}

  // 先读入本地配置（服务器、线路、代理、UA），再启动界面
  final container = ProviderContainer();
  await container.read(configProvider.notifier).load();
  await PlayHistory.load();
  runApp(UncontrolledProviderScope(container: container, child: const VioraApp()));
}
