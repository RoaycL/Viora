import 'package:flutter/painting.dart';

enum ServerStatus { ok, fallback, down }

class MockServer {
  const MockServer(
    this.name,
    this.type,
    this.note,
    this.lastAccess,
    this.movies,
    this.series,
    this.icon, {
    this.adult = false,
    this.status = ServerStatus.ok,
  });

  final String name;
  final String type;
  final String note;
  final String lastAccess;
  final int? movies;
  final int? series;
  final Gradient icon;
  final bool adult;
  final ServerStatus status;
}

LinearGradient _g(int a, int b) =>
    LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(a), Color(b)]);

/// M0 假数据，与效果图「资源库」一致。
abstract final class LibraryMock {
  static final servers = <MockServer>[
    MockServer('私服', 'EMBY', '主线路 · 直连 38ms', '6 天前', 17083, 75, _g(0xFF4A4A5A, 0xFF18181F)),
    MockServer('探花 TV', 'EMBY', '主线路 · 代理', '26 天前', 12418, 293, _g(0xFFFFB3C7, 0xFFE05A86), adult: true),
    MockServer('步兵营地', 'EMBY', '14 天后到期', '2 天前', 23777, 2432, _g(0xFF6B8CA8, 0xFF1E2D3D), adult: true),
    MockServer('peach_公益服', 'EMBY', '15 天观看 · 代理', '9 天前', 11021, 7922, _g(0xFFFFB36B, 0xFFE0533C)),
    MockServer('FWorks Network', 'JELLYFIN', '21 天观看', '10 天前', 1907, 3036, _g(0xFF2B2B2B, 0xFF000000)),
    MockServer(
      'Youno',
      'EMBY',
      'CF 线路（主线路超时）',
      '5 天前',
      29299,
      17501,
      _g(0xFF3E4A5C, 0xFF12161C),
      status: ServerStatus.fallback,
    ),
    MockServer('起点站', 'EMBY', '30 天观看', '24 天前', 0, 7202, _g(0xFFFFD36B, 0xFFF08A24)),
    MockServer('ChaPanda', 'EMBY', '30 天 · 代理 86ms', '25 天前', 19578, 9178, _g(0xFF8FD3FF, 0xFF2D7FD3)),
    MockServer('游骑兵', 'EMBY', '主线路', '6 天前', 8240, 1903, _g(0xFFC86BFF, 0xFF5A1E8C), adult: true),
    MockServer('飞跃彩虹', 'PLEX', '远程连接 · 2 条线路', '24 天前', 10366, 1145, _g(0xFF7CFFB2, 0xFF2E9C6A)),
    MockServer('家里 NAS', '飞牛', '局域网 · 直连', '今天', 1280, 96, _g(0xFF8FA2FF, 0xFF3B4CC0)),
    MockServer(
      'cc 公益',
      'JELLYFIN',
      '全部线路不可用',
      '40 天前',
      null,
      null,
      _g(0xFF9A9A9A, 0xFF4A4A4A),
      status: ServerStatus.down,
    ),
  ];
}
