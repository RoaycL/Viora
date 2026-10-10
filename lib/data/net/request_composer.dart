import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../config/app_config.dart';

/// 请求类型：决定是否走代理、用哪个 UA。
enum RequestKind { api, image, stream }

/// 把原始地址改写成 emby-reverse-proxy-go 的格式：
/// `{完整地址}/{scheme}/{host}/{port}{path}?{query}`（端口总是显式写出）。
///
/// 已经是代理地址的不再改写（服务器返回的地址可能已被代理改写过）。
Uri proxify(Uri original, String proxyBase) {
  final base = proxyBase.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty) return original;
  if (original.toString().startsWith('$base/')) return original;
  final port = original.hasPort ? original.port : (original.scheme == 'https' ? 443 : 80);
  final path = original.path.isEmpty ? '/' : original.path;
  final query = original.hasQuery ? '?${original.query}' : '';
  return Uri.parse('$base/${original.scheme}/${original.host}/$port$path$query');
}

/// [proxify] 的逆操作：把代理地址还原成原始地址；不是代理地址时返回 null。
Uri? unproxify(Uri proxied, String proxyBase) {
  final base = proxyBase.trim().replaceAll(RegExp(r'/+$'), '');
  final s = proxied.toString();
  if (base.isEmpty || !s.startsWith('$base/')) return null;
  final m = RegExp(r'^/(https?)/([^/]+)/(\d+)(/[^?#]*)?(\?.*)?$').firstMatch(s.substring(base.length));
  if (m == null) return null;
  final scheme = m[1]!;
  final port = int.parse(m[3]!);
  final defaultPort = scheme == 'https' ? 443 : 80;
  return Uri.parse('$scheme://${m[2]}${port == defaultPort ? '' : ':$port'}${m[4] ?? '/'}${m[5] ?? ''}');
}

/// 默认 UA，例如 `Viora/0.2.0 (Windows)`。
String defaultUserAgent(String appVersion) {
  final os = kIsWeb
      ? 'Web'
      : Platform.isAndroid
      ? 'Android TV'
      : Platform.isWindows
      ? 'Windows'
      : Platform.operatingSystem;
  return 'Viora/$appVersion ($os)';
}

String defaultDeviceName() => kIsWeb
    ? 'Web'
    : Platform.isAndroid
    ? 'Android TV'
    : Platform.isWindows
    ? 'Windows PC'
    : Platform.operatingSystem;

/// 根据配置生成最终的 URL 与请求头（docs/02-architecture.md §5）。
class RequestComposer {
  RequestComposer({required this.config, required this.server, required this.line, required this.appVersion});

  final AppConfig config;
  final ServerConfig server;
  final ServerLine line;
  final String appVersion;

  /// 服务器 API 根地址（Emby 默认带 /emby 前缀）
  Uri get apiBase {
    final u = Uri.parse(line.url.trim());
    var path = u.path.replaceAll(RegExp(r'/+$'), '');
    if (server.type == ServerType.emby && !path.toLowerCase().endsWith('/emby')) path = '$path/emby';
    return u.replace(path: path);
  }

  Uri resolve(String path, [Map<String, String>? query]) {
    final base = apiBase;
    return base.replace(
      path: '${base.path}${path.startsWith('/') ? path : '/$path'}',
      queryParameters: query == null || query.isEmpty ? null : query,
    );
  }

  bool usesProxy(RequestKind kind) {
    if (!line.proxied || !config.proxy.enabled) return false;
    // 内网地址（192.168.x.x、10.x.x.x、NAS 主机名等）不能走公网上的反向代理：代理服务器连不到你家里的网络
    if (isLanHost(Uri.tryParse(line.url.trim())?.host ?? '')) return false;
    // API、图片、视频流一起走代理
    return true;
  }

  Uri finalUrl(Uri original, RequestKind kind) => usesProxy(kind) ? proxify(original, config.proxy.baseUrl) : original;

  /// 播放 UA：服务器覆盖 > 全局设置 > 默认
  String get playbackUserAgent {
    final custom = server.userAgent?.trim().isNotEmpty == true
        ? server.userAgent!.trim()
        : config.playback.userAgent.trim();
    return custom.isNotEmpty ? custom : defaultUserAgent(appVersion);
  }

  String userAgentFor(RequestKind kind) =>
      kind == RequestKind.stream || config.playback.uaForApi ? playbackUserAgent : defaultUserAgent(appVersion);

  String get _clientName => config.playback.clientName.trim().isEmpty ? 'Viora' : config.playback.clientName.trim();

  String get _deviceName =>
      config.playback.deviceName.trim().isEmpty ? defaultDeviceName() : config.playback.deviceName.trim();

  /// `MediaBrowser Client="Viora", Device="...", DeviceId="...", Version="..."[, Token="..."]`
  String authorization({bool withToken = true}) {
    String q(String v) => v.replaceAll('"', "'");
    final parts = [
      'Client="${q(_clientName)}"',
      'Device="${q(_deviceName)}"',
      'DeviceId="${q('${config.deviceId}-${server.id}')}"',
      'Version="${q(appVersion)}"',
      if (withToken && server.token != null) 'Token="${server.token}"',
    ];
    return 'MediaBrowser ${parts.join(', ')}';
  }

  Map<String, String> headers(RequestKind kind) {
    final h = <String, String>{'User-Agent': userAgentFor(kind), 'Accept-Language': 'zh-CN,zh;q=0.9'};
    final auth = authorization();
    switch (server.type) {
      case ServerType.emby:
        h['X-Emby-Authorization'] = auth;
        if (server.token != null) h['X-Emby-Token'] = server.token!;
      case ServerType.jellyfin:
        h['Authorization'] = auth;
    }
    return h;
  }
}

/// 局域网地址：私有网段 IPv4、localhost、`.local` / `.lan` 或不带点的主机名（如 `nas`）
bool isLanHost(String host) {
  final h = host.trim().toLowerCase();
  if (h.isEmpty) return false;
  if (h == 'localhost' || h.endsWith('.local') || h.endsWith('.lan') || h.endsWith('.home')) return true;
  final ip = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(h);
  if (ip != null) {
    final a = int.parse(ip[1]!), b = int.parse(ip[2]!);
    return a == 10 || a == 127 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31) || (a == 169 && b == 254);
  }
  if (h.startsWith('[') || h.contains(':')) return h.startsWith('[fe80') || h.startsWith('[fd') || h.startsWith('fd');
  return !h.contains('.');
}
