import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/net/request_composer.dart';

void main() {
  const base = 'https://embyproxy.example.com/proxy/';

  group('emby-reverse-proxy-go 地址改写', () {
    test('显式写出默认端口', () {
      expect(
        proxify(Uri.parse('https://emby.a.com/emby/Items?x=1'), base).toString(),
        'https://embyproxy.example.com/proxy/https/emby.a.com/443/emby/Items?x=1',
      );
      expect(
        proxify(Uri.parse('http://emby.a.com:8096/Videos/1/stream.mkv?Static=true'), base).toString(),
        'https://embyproxy.example.com/proxy/http/emby.a.com/8096/Videos/1/stream.mkv?Static=true',
      );
    });

    test('已经是代理地址的不重复改写', () {
      final once = proxify(Uri.parse('https://emby.a.com/emby/Items'), base);
      expect(proxify(once, base), once);
    });

    test('可以还原成原始地址', () {
      final proxied = Uri.parse('https://embyproxy.example.com/proxy/https/cdn.pan.com/443/file.mkv?sign=abc');
      expect(unproxify(proxied, base).toString(), 'https://cdn.pan.com/file.mkv?sign=abc');
      expect(
        unproxify(Uri.parse('https://embyproxy.example.com/proxy/http/a.com/8096/x'), base).toString(),
        'http://a.com:8096/x',
      );
      expect(unproxify(Uri.parse('https://other.com/x'), base), isNull);
    });
  });

  group('RequestComposer', () {
    ServerConfig server(ServerType type, {String? ua}) => ServerConfig(
      id: 's1',
      type: type,
      name: 'test',
      username: 'u',
      token: 'tok',
      userId: 'uid',
      userAgent: ua,
      lines: const [ServerLine(id: 'l1', name: '主线路', url: 'https://emby.a.com', proxied: true)],
    );

    RequestComposer composer(ServerConfig s, {AppConfig config = const AppConfig(deviceId: 'dev')}) =>
        RequestComposer(config: config, server: s, line: s.lines.first, appVersion: '0.2.0');

    test('Emby 自动补 /emby 前缀，Jellyfin 不补', () {
      expect(
        composer(server(ServerType.emby)).resolve('/Users/uid/Views').toString(),
        'https://emby.a.com/emby/Users/uid/Views',
      );
      expect(
        composer(server(ServerType.jellyfin)).resolve('/Users/uid/Views').toString(),
        'https://emby.a.com/Users/uid/Views',
      );
    });

    test('线路绑定代理且配置了完整地址时改写', () {
      final c = composer(
        server(ServerType.emby),
        config: const AppConfig(
          deviceId: 'dev',
          proxy: ProxyConfig(baseUrl: base, scope: ProxyScope.streamOnly),
        ),
      );
      final api = c.resolve('/Items');
      expect(c.finalUrl(api, RequestKind.api), api);
      expect(c.finalUrl(api, RequestKind.stream).toString(), startsWith('https://embyproxy.example.com/proxy/https/'));
    });

    test('播放 UA：服务器覆盖 > 全局 > 默认；API 默认不用播放 UA', () {
      const global = AppConfig(
        deviceId: 'dev',
        playback: PlaybackConfig(userAgent: 'Global/1'),
      );
      expect(composer(server(ServerType.emby), config: global).headers(RequestKind.stream)['User-Agent'], 'Global/1');
      expect(
        composer(server(ServerType.emby, ua: 'Server/2'), config: global).headers(RequestKind.stream)['User-Agent'],
        'Server/2',
      );
      expect(
        composer(server(ServerType.emby), config: global).headers(RequestKind.api)['User-Agent'],
        startsWith('Viora/'),
      );
    });

    test('鉴权头', () {
      final emby = composer(server(ServerType.emby)).headers(RequestKind.api);
      expect(emby['X-Emby-Token'], 'tok');
      expect(emby['X-Emby-Authorization'], contains('Client="Viora"'));
      final jf = composer(server(ServerType.jellyfin)).headers(RequestKind.api);
      expect(jf['Authorization'], contains('Token="tok"'));
    });
  });
}
