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

    test('线路绑定代理且配置了完整地址时改写：API 和视频流一起走代理', () {
      final c = composer(
        server(ServerType.emby),
        config: const AppConfig(
          deviceId: 'dev',
          proxy: ProxyConfig(baseUrl: base),
        ),
      );
      final api = c.resolve('/Items');
      expect(c.finalUrl(api, RequestKind.api).toString(), startsWith('https://embyproxy.example.com/proxy/https/'));
      expect(c.finalUrl(api, RequestKind.stream).toString(), startsWith('https://embyproxy.example.com/proxy/https/'));
      // 没勾选代理的线路直连
      final direct = RequestComposer(
        config: const AppConfig(
          deviceId: 'dev',
          proxy: ProxyConfig(baseUrl: base),
        ),
        server: server(ServerType.emby),
        line: const ServerLine(id: 'l2', name: '直连', url: 'https://emby.a.com'),
        appVersion: '0.2.0',
      );
      expect(direct.finalUrl(api, RequestKind.stream), api);
    });

    test('内网地址即使勾了走反向代理也直连（公网代理连不到家里的网络）', () {
      const lan = ServerConfig(
        id: 's2',
        type: ServerType.emby,
        name: 'nas',
        username: 'u',
        lines: [ServerLine(id: 'l', name: '内网', url: 'http://192.168.1.10:8096', proxied: true)],
      );
      final c = RequestComposer(
        config: const AppConfig(
          deviceId: 'dev',
          proxy: ProxyConfig(baseUrl: base),
        ),
        server: lan,
        line: lan.lines.first,
        appVersion: '0.2.0',
      );
      final api = c.resolve('/Users/AuthenticateByName');
      expect(c.usesProxy(RequestKind.api), isFalse);
      expect(c.finalUrl(api, RequestKind.api).toString(), 'http://192.168.1.10:8096/emby/Users/AuthenticateByName');
    });

    test('局域网地址识别', () {
      for (final h in [
        '192.168.1.2',
        '10.0.0.5',
        '172.16.3.4',
        '172.31.0.1',
        'localhost',
        'nas',
        'nas.local',
        'pi.lan',
      ]) {
        expect(isLanHost(h), isTrue, reason: h);
      }
      for (final h in ['emby.a.com', '8.8.8.8', '172.32.0.1', '1.2.3.4', '']) {
        expect(isLanHost(h), isFalse, reason: h);
      }
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

    test('服务器单独指定的 UA 用于这台服务器的所有请求（登录、API 也要过 UA 白名单）', () {
      final c = composer(server(ServerType.emby, ua: 'Forward/1.0'));
      for (final k in RequestKind.values) {
        expect(c.headers(k)['User-Agent'], 'Forward/1.0', reason: k.name);
      }
    });

    test('设备 ID 只和本机、服务器地址、用户名有关：删掉重新添加不会在服务器上多一台设备', () {
      final a = composer(server(ServerType.emby));
      final readded = composer(server(ServerType.emby).copyWith(name: '改名了'));
      final other = composer(
        const ServerConfig(
          id: 'another-id',
          type: ServerType.emby,
          name: 'x',
          username: 'U ',
          lines: [ServerLine(id: 'l9', name: '线路', url: 'https://EMBY.a.com/')],
        ),
      );
      expect(a.deviceId, startsWith('dev-'));
      expect(readded.deviceId, a.deviceId);
      expect(other.deviceId, a.deviceId);
      expect(a.authorization(), contains('DeviceId="${a.deviceId}"'));
      final otherUser = composer(server(ServerType.emby).copyWith(username: 'v'));
      expect(otherUser.deviceId, isNot(a.deviceId));
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
