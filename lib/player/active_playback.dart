import 'dart:async';

/// 正在播放的播放页：应用直接退出（Windows 托盘「退出」、关闭窗口、应用内更新重启）时播放页不会被销毁，
/// 要先让它上报停止（服务器记下最后的进度、结束「正在播放」），再结束进程
abstract final class ActivePlayback {
  static final _stops = <Object, Future<void> Function()>{};

  static void register(Object owner, Future<void> Function() stop) => _stops[owner] = stop;

  static void unregister(Object owner) => _stops.remove(owner);

  /// 让所有播放页上报停止，最多等 [timeout]
  static Future<void> stopAll({Duration timeout = const Duration(seconds: 3)}) async {
    if (_stops.isEmpty) return;
    try {
      await Future.wait([for (final stop in _stops.values.toList()) stop()]).timeout(timeout);
    } catch (_) {}
  }
}
