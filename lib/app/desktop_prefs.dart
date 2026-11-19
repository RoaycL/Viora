import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'window_frame.dart';

/// 桌面图标样式（Windows：任务栏、托盘、桌面和开始菜单的快捷方式，以及应用左上角的 Logo）
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
  static const _kShortcutIcon = 'viora.window.shortcutIconLight';

  /// 上次改快捷方式图标时的 exe（路径 + 修改时间）：没更新过应用就不用每次启动都跑 PowerShell
  static const _kShortcutExe = 'viora.window.shortcutIconExe';
  static const _kNavCompact = 'viora.window.navCompact';

  /// 左侧导航栏样式：false = 默认（一长条，设置在最下面），true = 紧凑（高度随项目、上下居中）
  final navCompact = ValueNotifier(false);

  Future<void> setNavCompact(bool v) => _setBool(_kNavCompact, navCompact, v);

  /// 打开软件时全屏
  final fullScreenOnLaunch = ValueNotifier(false);

  /// 开始播放时全屏（退出播放后恢复原来的窗口）
  final fullScreenOnPlay = ValueNotifier(false);

  /// 网络请求和播放跟随 Windows 系统代理（Clash 等工具开的系统代理）
  final followSystemProxy = ValueNotifier(false);

  final iconStyle = ValueNotifier(AppIconStyle.dark);

  /// 现在实际用哪套桌面图标（跟随系统时看系统是浅色还是深色）
  final lightIcon = ValueNotifier(false);

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      fullScreenOnLaunch.value = p.getBool(_kLaunchFull) ?? false;
      fullScreenOnPlay.value = p.getBool(_kPlayFull) ?? false;
      followSystemProxy.value = p.getBool(_kSystemProxy) ?? false;
      iconStyle.value = AppIconStyle.values.asNameMap()[p.getString(_kIcon)] ?? AppIconStyle.dark;
      navCompact.value = p.getBool(_kNavCompact) ?? false;
    } catch (_) {}
    // 用观察者监听系统深浅色变化：直接改 PlatformDispatcher.onPlatformBrightnessChanged 会顶掉 Flutter 自己的处理
    // （MediaQuery.platformBrightness 不再更新）
    WidgetsBinding.instance.addObserver(_BrightnessObserver(_applyIcon));
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
    _applyShortcuts(light);
  }

  /// 桌面、开始菜单、任务栏固定的「Viora」快捷方式换图标。
  /// 日间图标每次启动都设一次（应用更新时安装程序会把快捷方式改回 exe 自带的深色图标）；
  /// 换回默认时只在之前设过日间图标时改回一次。做不到（没有权限、找不到快捷方式）就算了，不影响使用
  Future<void> _applyShortcuts(bool light) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final was = prefs.getBool(_kShortcutIcon) ?? false;
      if (!light && !was) return;
      final exe = Platform.resolvedExecutable;
      // 日间图标：应用更新后安装程序会把快捷方式改回深色图标，所以 exe 变了（路径或修改时间）才重新设
      final stamp = '$exe|${File(exe).lastModifiedSync().millisecondsSinceEpoch}';
      if (light && was && prefs.getString(_kShortcutExe) == stamp) return;
      final dir = File(exe).parent.path;
      final icon = light ? '$dir\\data\\flutter_assets\\assets\\images\\app_icon_light.ico,0' : '$exe,0';
      final env = Platform.environment;
      final candidates = [
        if (env['USERPROFILE'] != null) '${env['USERPROFILE']}\\Desktop\\Viora.lnk',
        if (env['PUBLIC'] != null) '${env['PUBLIC']}\\Desktop\\Viora.lnk',
        if (env['APPDATA'] != null) '${env['APPDATA']}\\Microsoft\\Windows\\Start Menu\\Programs\\Viora.lnk',
        if (env['ProgramData'] != null) '${env['ProgramData']}\\Microsoft\\Windows\\Start Menu\\Programs\\Viora.lnk',
        if (env['APPDATA'] != null)
          '${env['APPDATA']}\\Microsoft\\Internet Explorer\\Quick Launch\\User Pinned\\TaskBar\\Viora.lnk',
      ].where((p) => File(p).existsSync()).toList();
      if (candidates.isNotEmpty) {
        final script = StringBuffer(r'$w = New-Object -ComObject WScript.Shell;');
        for (final p in candidates) {
          final q = p.replaceAll("'", "''");
          script.write(
            " try { \$s = \$w.CreateShortcut('$q'); \$s.IconLocation = '${icon.replaceAll("'", "''")}'; \$s.Save() } catch {};",
          );
        }
        await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', script.toString()]);
      }
      await prefs.setBool(_kShortcutIcon, light);
      await prefs.setString(_kShortcutExe, stamp);
    } catch (e) {
      debugPrint('shortcut icon: $e');
    }
  }
}

/// Windows 系统代理（「设置 → 网络和 Internet → 代理」，Clash 等工具开的就是这个）。
///
/// 打开「跟随系统代理」后，应用里所有的 HTTP 请求（Dart 的 HttpClient：接口、图片、TMDB、更新等）和 mpv 播放都走它。
/// 局域网地址、系统代理设置里「不使用代理」的地址照常直连
abstract final class SystemProxy {
  /// 当前生效的代理（host:port），没有时为 null
  static String? current;
  static List<String> _bypass = const [];

  /// 按「跟随系统代理」开关重新读取系统代理（开始播放前调用：启动后系统代理可能开了或关了）
  static Future<void> refresh() => apply(DesktopPrefs.instance.followSystemProxy.value);

  /// 读取系统代理并应用（关闭时恢复直连）
  static Future<void> apply(bool enabled) async {
    if (!enabled || !Platform.isWindows) {
      current = null;
      // 只撤掉自己设的（测试环境等别处设的不动）
      if (HttpOverrides.current is _ProxyOverrides) HttpOverrides.global = null;
      return;
    }
    final read = await readWindows();
    current = read?.$1;
    _bypass = read?.$2 ?? const [];
    if (current != null) {
      if (HttpOverrides.current is! _ProxyOverrides) HttpOverrides.global = _ProxyOverrides();
    } else if (HttpOverrides.current is _ProxyOverrides) {
      HttpOverrides.global = null;
    }
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

class _BrightnessObserver with WidgetsBindingObserver {
  _BrightnessObserver(this.onChanged);
  final VoidCallback onChanged;

  @override
  void didChangePlatformBrightness() => onChanged();
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
