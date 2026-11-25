import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/download/downloads.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/media/media_models.dart';

/// 假服务器：/Videos/x1/stream.mkv 返回 [body]，支持 Range；[gate] 不为空时发完前一半后等它
class _Fake {
  _Fake(this.http, this.body);
  final HttpServer http;
  final List<int> body;
  final ranges = <String?>[];
  Completer<void>? gate;

  static Future<_Fake> start(List<int> body) async {
    final f = _Fake(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), body);
    f.http.listen((req) async {
      final range = req.headers.value('range');
      f.ranges.add(range);
      var from = 0;
      if (range != null) {
        from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        req.response.statusCode = 206;
      }
      final rest = f.body.sublist(from);
      req.response.contentLength = rest.length;
      final half = rest.length ~/ 2;
      req.response.add(rest.sublist(0, half));
      await req.response.flush();
      if (f.gate != null) await f.gate!.future;
      try {
        req.response.add(rest.sublist(half));
        await req.response.close();
      } catch (_) {}
    });
    return f;
  }

  String get url => 'http://127.0.0.1:${http.port}';
}

EmbyClient _client(String url) {
  final server = ServerConfig(
    id: 's',
    type: ServerType.emby,
    name: 'home',
    username: 'alice',
    userId: 'u1',
    token: 'token',
    lines: [ServerLine(id: 'l', name: 'main', url: url)],
  );
  return EmbyClient(
    config: AppConfig(servers: [server]),
    server: server,
    appVersion: 'test',
  );
}

const _item = MediaItem(serverId: 's', id: 'x1', kind: MediaKind.movie, name: '电影: 测试/1');
const _source = MediaSourceInfo(
  serverId: 's',
  itemId: 'x1',
  id: 'src1',
  container: 'mkv',
  size: 4000,
  streams: [MediaStreamInfo(index: 0, type: 'Video', codec: 'hevc', width: 3840, height: 2160)],
);

Future<void> _until(bool Function() ok) async {
  for (var i = 0; i < 200 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('viora-dl');
    Downloads.debugDir = dir.path;
    Downloads.instance.debugReset();
  });
  tearDown(() async {
    Downloads.instance.debugReset();
    await dir.delete(recursive: true);
  });

  test('下载完整文件，保存列表；重新读取后能找到可播放的文件，离线进度也记下', () async {
    final body = List<int>.generate(4000, (i) => i % 251);
    final fake = await _Fake.start(body);
    addTearDown(() => fake.http.close(force: true));
    final e = await Downloads.instance.add(_client(fake.url), _item, _source);
    await _until(() => e.state == DownloadState.done);
    expect(e.state, DownloadState.done);
    expect(File(e.path).readAsBytesSync(), body);
    expect(e.path, endsWith('电影 测试 1 [x1].mkv'));

    Downloads.instance.recordProgress('s', 'x1', const Duration(minutes: 5), played: false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    Downloads.instance.debugReset();
    await Downloads.instance.load();
    final back = Downloads.instance.playable('s', 'x1')!;
    expect(back.path, e.path);
    expect(back.position, const Duration(minutes: 5));
    expect(back.source.video?.width, 3840);
    expect(Downloads.instance.playable('s', 'x1', sourceId: 'other'), isNull);
  });

  test('暂停后继续：从已下载的位置断点续传', () async {
    // 要够大：服务器端小数据会攒着不发，flush 了客户端也收不到前一半
    final body = List<int>.generate(400000, (i) => i % 7);
    final fake = await _Fake.start(body)
      ..gate = Completer<void>();
    addTearDown(() => fake.http.close(force: true));
    final client = _client(fake.url);
    final e = await Downloads.instance.add(client, _item, _source);
    await _until(() => e.received >= 200000);
    Downloads.instance.pause(e);
    await _until(() => e.state == DownloadState.paused);
    await Downloads.instance.debugIdle;
    final got = File(e.partPath).lengthSync();
    expect(got, 200000);
    fake.gate!.complete();
    fake.gate = null;
    Downloads.instance.resume(e, client);
    await _until(() => e.state == DownloadState.done);
    expect(fake.ranges.last, 'bytes=200000-');
    expect(File(e.path).readAsBytesSync(), body);
  });

  test('删除下载连同文件', () async {
    final fake = await _Fake.start(List<int>.filled(4000, 1));
    addTearDown(() => fake.http.close(force: true));
    final e = await Downloads.instance.add(_client(fake.url), _item, _source);
    await _until(() => e.state == DownloadState.done);
    await Downloads.instance.remove(e);
    expect(File(e.path).existsSync(), isFalse);
    expect(Downloads.instance.entries, isEmpty);
  });
}
