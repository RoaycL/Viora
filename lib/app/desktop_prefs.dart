import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'window_frame.dart';

/// 应用图标样式（Windows：左上角 Logo、任务栏图标）
enum AppIconStyle {
  /// 深色底（现在的图标）
  dark('默认'),

  /// 白色底、带一点光泽的日间图标
  light('日间'),

  /// 跟随系统：系统浅色模式用日间图标，深色模式用默认图标
  system('跟随系统');

  const AppIconStyle(this.label);
  final String label;
}

/// Windows 本机设置：不随 WebDAV / 局域网同步到其他设备（每台电脑的显示器、网络环境不一样）
class DesktopPrefs {
  DesktopPrefs._();
  static final instance = DesktopPrefs._();

  static const _kLaunchFull = 'viora.window.fullScreenOnLaunch';
  static const _kPlayFull = 'viora.window.fullScreenOnPlay';
  static const _kSystemProxy = 'viora.net.systemProxy';
  static const _kIcon = 'viora.window.iconStyle';

  /// 打开软件时全屏
  final fullScreenOnLaunch = ValueNotifier(false);

  /// 开始播放时全屏（退出播放后恢复原来的窗口）
  final fullScreenOnPlay = ValueNotifier(false);

  /// 网络请求和播放跟随 Windows 系统代理（Clash 等工具开的系统代理）
  final followSystemProxy = ValueNotifier(false);

  final iconStyle = ValueNotifier(AppIconStyle.dark);

  /// 现在实际用哪套图标（跟随系统时看系统是浅色还是深色）
  final lightIcon = ValueNotifier(false);

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      fullScreenOnLaunch.value = p.getBool(_kLaunchFull) ?? false;
      fullScreenOnPlay.value = p.getBool(_kPlayFull) ?? false;
      followSystemProxy.value = p.getBool(_kSystemProxy) ?? false;
      iconStyle.value = AppIconStyle.values.asNameMap()[p.getString(_kIcon)] ?? AppIconStyle.dark;
    } catch (_) {}
    PlatformDispatcher.instance.onPlatformBrightnessChanged = _applyIcon;
    _applyIcon();
  }

  Future<void> _setBool(String key, ValueNotifier<bool> n, bool v) async {
    n.value = v;
    try {
      await (await SharedPreferences.getInstance()).setBool(key, v);
    } catch (_) {}
  }

  Future<void> setFullScreenOnLaunch(bool v) => _setBool(_kLaunchFull, fullScreenOnLaunch, v);
  Future<void> setFullScreenOnPlay(bool v) => _setBool(_kPlayFull, fullScreenOnPlay, v);

  Future<void> setFollowSystemProxy(bool v) async {
    await _setBool(_kSystemProxy, followSystemProxy, v);
    SystemProxy.apply(v);
  }

  Future<void> setIconStyle(AppIconStyle v) async {
    iconStyle.value = v;
    try {
      await (await SharedPreferences.getInstance()).setString(_kIcon, v.name);
    } catch (_) {}
    _applyIcon();
  }

  void _applyIcon() {
    final light = switch (iconStyle.value) {
      AppIconStyle.dark => false,
      AppIconStyle.light => true,
      AppIconStyle.system => PlatformDispatcher.instance.platformBrightness == Brightness.light,
    };
    lightIcon.value = light;
    if (!isDesktopWindow) return;
    windowManager.setIcon(light ? 'assets/images/app_icon_light.ico' : 'assets/images/app_icon.ico').catchError((_) {});
  }

  static String logoAsset(bool light) => light ? 'assets/images/app_icon_light.png' : 'assets/images/app_icon.png';
}

/// Windows 系统代理（「设置 → 网络和 Internet → 代理」，Clash 等工具开的就是这个）。
///
/// 打开「跟随系统代理」后，应用里所有的 HTTP 请求（Dart 的 HttpClient：接口、图片、TMDB、更新等）和 mpv 播放都走它。
/// 局域网地址、系统代理设置里「不使用代理」的地址照常直连
abstract final class SystemProxy {
  /// 当前生效的代理（host:port），没有时为 null
  static String? current;
  static List<String> _bypass = const [];

  /// 读取系统代理并应用（关闭时恢复直连）
  static Future<void> apply(bool enabled) async {
    if (!enabled || !Platform.isWindows) {
      current = null;
      HttpOverrides.global = null;
      return;
    }
    final read = await readWindows();
    current = read?.$1;
    _bypass = read?.$2 ?? const [];
    HttpOverrides.global = current == null ? null : _ProxyOverrides();
    debugPrint('system proxy: ${current ?? '未开启'}');
  }

  /// 读注册表里的系统代理：(地址, 不使用代理的地址)；系统没开代理时返回 null
  static Future<(String, List<String>)?> readWindows() async {
    try {
      const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
      final r = await Process.run('reg', ['query', key]);
      if (r.exitCode != 0) return null;
      return parseRegQuery(r.stdout as String);
    } catch (_) {
      return null;
    }
  }

  /// 解析 `reg query` 的输出。ProxyServer 可能是「host:port」，也可能是「http=host:port;https=host:port」
  @visibleForTesting
  static (String, List<String>)? parseRegQuery(String out) {
    String? value(String name) =>
        RegExp('^\\s*$name\\s+REG_\\w+\\s+(.*)\$', multiLine: true).firstMatch(out)?.group(1)?.trim();
    final enable = value('ProxyEnable');
    if (enable == null || int.tryParse(enable.replaceFirst('0x', ''), radix: 16) != 1) return null;
    final server = value('ProxyServer');
    if (server == null || server.isEmpty) return null;
    String? pick(String scheme) => server
        .split(';')
        .map((e) => e.trim())
        .where((e) => e.startsWith('$scheme='))
        .firstOrNull
        ?.substring(scheme.length + 1);
    final proxy = server.contains('=') ? (pick('https') ?? pick('http') ?? pick('socks')) : server;
    if (proxy == null || proxy.isEmpty) return null;
    final bypass = (value('ProxyOverride') ?? '')
        .split(';')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty);
    return (proxy.replaceFirst(RegExp(r'^\w+://'), ''), bypass.toList());
  }

  /// 这个地址要不要直连：局域网 / 本机地址、系统设置里「不使用代理」的地址
  @visibleForTesting
  static bool direct(String host, [List<String>? bypass]) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h.startsWith('127.') || h == '::1') return true;
    if (RegExp(r'^(10\.|192\.168\.|169\.254\.)').hasMatch(h)) return true;
    final m = RegExp(r'^172\.(\d+)\.').firstMatch(h);
    if (m != null && int.parse(m[1]!) >= 16 && int.parse(m[1]!) <= 31) return true;
    for (final b in bypass ?? _bypass) {
      if (b == '<local>') {
        if (!h.contains('.')) return true;
        continue;
      }
      final pattern = RegExp('^${RegExp.escape(b).replaceAll(r'\*', '.*')}\$');
      if (pattern.hasMatch(h)) return true;
    }
    return false;
  }

  /// mpv 的 http-proxy 参数（播放也走系统代理）；直连的地址返回 null
  static String? forMpv(Uri url) => current == null || direct(url.host) ? null : 'http://$current';
}

class _ProxyOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) {
      final proxy = SystemProxy.current;
      if (proxy == null || SystemProxy.direct(uri.host)) return 'DIRECT';
      return 'PROXY $proxy; DIRECT';
    };
    return client;
  }
}
