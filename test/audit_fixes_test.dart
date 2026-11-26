import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/core/log/app_log.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/index/media_index.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/data/media/series_ratings.dart';
import 'package:viora/data/net/request_composer.dart';
import 'package:viora/features/update/app_version.dart';
import 'package:viora/features/update/update_controller.dart';
import 'package:viora/player/active_playback.dart';
import 'package:viora/player/engine.dart';
import 'package:viora/player/exo_engine.dart';

ServerConfig _server(ServerType type, {String url = 'https://emby.a.com'}) => ServerConfig(
  id: 's',
  type: type,
  name: 'home',
  username: 'alice',
  userId: 'u1',
  token: 'tok',
  lines: [ServerLine(id: 'l', name: 'main', url: url)],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('视频流请求头不带令牌（302 到网盘 / CDN 时不外泄）', () {
    RequestComposer composer(ServerType type) {
      final s = _server(type);
      return RequestComposer(
        config: const AppConfig(deviceId: 'dev'),
        server: s,
        line: s.lines.first,
        appVersion: '1',
      );
    }

    test('Emby / Jellyfin：流请求只带 UA，接口请求照常带令牌', () {
      for (final type in [ServerType.emby, ServerType.jellyfin]) {
        final stream = composer(type).headers(RequestKind.stream);
        expect(stream.keys, isNot(contains('X-Emby-Token')));
        expect(stream.keys, isNot(contains('X-Emby-Authorization')));
        expect(stream.keys, isNot(contains('Authorization')));
        expect(stream['User-Agent'], isNotEmpty);
      }
      expect(composer(ServerType.emby).headers(RequestKind.api)['X-Emby-Token'], 'tok');
      expect(composer(ServerType.jellyfin).headers(RequestKind.api)['Authorization'], contains('Token="tok"'));
    });

    test('飞牛的视频流必须带 Authorization，不受影响', () {
      expect(composer(ServerType.fnos).headers(RequestKind.stream)['Authorization'], 'tok');
    });

    test('视频流地址里带 api_key', () {
      final c = EmbyClient(
        config: AppConfig(servers: [_server(ServerType.jellyfin)]),
        server: _server(ServerType.jellyfin),
        appVersion: 't',
      );
      const source = MediaSourceInfo(serverId: 's', itemId: 'i1', id: 'm1', container: 'mkv');
      expect(c.stream(source).url.queryParameters['api_key'], 'tok');
    });
  });

  group('外挂字幕地址', () {
    final server = _server(ServerType.emby);
    final client = EmbyClient(
      config: AppConfig(servers: [server]),
      server: server,
      appVersion: 't',
    );
    const source = MediaSourceInfo(serverId: 's', itemId: 'i1', id: 'm1', container: 'mkv');

    test('投递地址已带 /emby 前缀时不重复拼', () {
      const sub = MediaStreamInfo(
        index: 3,
        type: 'Subtitle',
        isExternal: true,
        deliveryUrl: '/emby/Videos/i1/m1/Subtitles/3/0/Stream.srt?api_key=tok',
      );
      expect(
        client.subtitle(source, sub)!.url.toString(),
        'https://emby.a.com/emby/Videos/i1/m1/Subtitles/3/0/Stream.srt?api_key=tok',
      );
    });

    test('标准的相对投递地址接到 /emby 后面', () {
      const sub = MediaStreamInfo(
        index: 3,
        type: 'Subtitle',
        isExternal: true,
        deliveryUrl: '/Videos/i1/m1/Subtitles/3/0/Stream.srt?api_key=tok',
      );
      expect(client.subtitle(source, sub)!.url.path, '/emby/Videos/i1/m1/Subtitles/3/0/Stream.srt');
    });

    test('服务器没给投递地址时自拼的路径补上 api_key', () {
      const sub = MediaStreamInfo(index: 2, type: 'Subtitle', isExternal: true, codec: 'subrip');
      final url = client.subtitle(source, sub)!.url;
      expect(url.path, '/emby/Videos/i1/m1/Subtitles/2/Stream.srt');
      expect(url.queryParameters['api_key'], 'tok');
    });
  });

  test('全量同步的代号马上记下：中断后再次全量换新代号，能清掉中断那次写入、之后被删的条目', () async {
    final index = (await MediaIndex.open(path: ':memory:'))!;
    addTearDown(index.close);
    MediaItem movie(String id) => MediaItem(serverId: 'a', id: id, kind: MediaKind.movie, name: id);
    final g1 = index.beginFull('a');
    index.upsert('a', [movie('gone')], gen: g1);
    // 中断：没有 finishFull
    final g2 = index.beginFull('a');
    expect(g2, greaterThan(g1));
    index.upsert('a', [movie('kept')], gen: g2);
    index.finishFull('a', g2);
    expect(index.count('a'), 1);
  });

  group('单集按所属剧集的分级判断（儿童模式）', () {
    setUp(SeriesRatings.clear);
    const p = ParentalConfig(enabled: true, maxAge: 7);
    const ep = MediaItem(serverId: 's', id: 'e1', kind: MediaKind.episode, name: 'ep', seriesId: 'show');

    test('剧集是 TV-MA：单集自己没填分级也拦', () {
      SeriesRatings.remember([
        const MediaItem(serverId: 's', id: 'show', kind: MediaKind.series, name: 'x', officialRating: 'TV-MA'),
      ]);
      expect(parentalAllowsItem(p, ep), isFalse);
    });

    test('剧集是少儿分级：放行', () {
      SeriesRatings.remember([
        const MediaItem(serverId: 's', id: 'show', kind: MediaKind.series, name: 'x', officialRating: 'TV-Y'),
      ]);
      expect(parentalAllowsItem(p, ep), isTrue);
    });

    test('不知道剧集分级：照旧放行（服务器端已过滤）；没记住时查索引', () {
      expect(parentalAllowsItem(p, ep), isTrue);
      SeriesRatings.lookupIndex = (_, _) => 'R';
      addTearDown(() => SeriesRatings.lookupIndex = null);
      expect(parentalAllowsItem(p, ep), isFalse);
    });
  });

  group('应用内更新', () {
    test('认不出的预发布后缀不当成正式版', () {
      expect(AppVersion.tryParse('v0.18.0-rc1'), isNull);
      expect(AppVersion.tryParse('v0.18.0-alpha1'), isNull);
      expect(AppVersion.tryParse('v0.17.8')?.isBeta, isFalse);
      expect(AppVersion.tryParse('0.17.8-beta3+76')?.beta, 3);
      expect(AppVersion.tryParse('0.17.8+76')?.build, 76);
    });

    test('只认 64 位十六进制的 SHA-256；安装包文件名固定', () {
      expect(isValidSha256(null), isFalse);
      expect(isValidSha256('abc'), isFalse);
      expect(isValidSha256('a' * 64), isTrue);
      expect(isValidSha256('A' * 64), isFalse); // 来源处已转小写
      expect(updateFileName(true), 'viora-update-setup.exe');
      expect(updateFileName(false), 'viora-update.apk');
    });
  });

  test('日志脱敏：地址和异常里的令牌、密码', () {
    final out = AppLog.redact(
      'DioException GET https://emby.a.com/emby/Videos/1/stream.mkv?Static=true&api_key=SECRET123 '
      'X-Plex-Token: PLEX456 Token="TOK789" https://bob:pw999@dav.example.com/x',
    );
    for (final secret in ['SECRET123', 'PLEX456', 'TOK789', 'pw999']) {
      expect(out, isNot(contains(secret)));
    }
    expect(out, contains('Static=true'));
    expect(out, contains('dav.example.com'));
  });

  test('退出前让播放页上报停止：等它完成，超时也不卡住退出', () async {
    final owner = Object();
    var stopped = false;
    ActivePlayback.register(owner, () async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      stopped = true;
    });
    final slow = Object();
    ActivePlayback.register(slow, () => Completer<void>().future);
    await ActivePlayback.stopAll(timeout: const Duration(milliseconds: 200));
    expect(stopped, isTrue);
    ActivePlayback.unregister(owner);
    ActivePlayback.unregister(slow);
  });

  group('ExoEngine 创建', () {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('viora/exo');
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    setUp(() {
      messenger.setMockStreamHandler(
        const EventChannel('viora/exo/events'),
        MockStreamHandler.inline(onListen: (_, _) {}),
      );
    });

    test('同时进来的几个调用只创建一个原生播放器', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'create') {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 7;
        }
        return null;
      });
      final engine = ExoEngine(options: const EngineOptions());
      await Future.wait([engine.setVolume(0.5), engine.setRate(1.5), engine.pause()]);
      expect(calls.where((m) => m == 'create').length, 1);
      await engine.dispose();
      expect(calls.last, 'dispose');
    });

    test('创建过程中就关掉：创建完成后马上销毁原生播放器', () async {
      final created = Completer<int>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'create' ? created.future : null;
      });
      final engine = ExoEngine(options: const EngineOptions());
      final pending = engine.pause();
      await Future<void>.delayed(Duration.zero);
      await engine.dispose();
      created.complete(9);
      await pending;
      final dispose = calls.where((c) => c.method == 'dispose').toList();
      expect(dispose, hasLength(1));
      expect((dispose.single.arguments as Map)['id'], 9);
      expect(calls.where((c) => c.method == 'pause'), isEmpty);
    });
  });
}
