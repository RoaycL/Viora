import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/ui/widgets/cached_image.dart';

/// 1×1 透明 PNG
const _png = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0B,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x60,
  0x00,
  0x02,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x7A,
  0x5E,
  0xAB,
  0x3F,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

Future<ImageInfo> _load(ImageProvider provider) {
  final done = Completer<ImageInfo>();
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener(
    (info, _) => done.isCompleted ? null : done.complete(info),
    onError: (e, _) => done.isCompleted ? null : done.completeError(e),
  );
  stream.addListener(listener);
  return done.future.timeout(const Duration(seconds: 10)).whenComplete(() => stream.removeListener(listener));
}

void main() {
  setUp(() => CachedNetImage.resetNetworkForTesting());

  testWidgets('网络图片能加载完成；同一张图同时加载两次都能完成（不会自己等自己）', (tester) async {
    await tester.runAsync(() async {
      HttpOverrides.global = null; // 测试环境默认拦截网络，这里用本机服务器
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((req) {
        requests++;
        req.response
          ..headers.contentType = ContentType('image', 'png')
          ..add(_png)
          ..close();
      });
      final url = 'http://127.0.0.1:${server.port}/poster.png';
      final results = await Future.wait([
        _load(CachedNetImage(url)),
        _load(ResizeImage(CachedNetImage(url), width: 1, allowUpscaling: true)),
      ]);
      expect(results.every((i) => i.image.width == 1), isTrue);
      expect(requests, 1);
      await server.close(force: true);
    });
  });

  testWidgets('多张图片复用 HTTP 连接，鉴权不同的相同 URL 不共用图片', (tester) async {
    await tester.runAsync(() async {
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final ports = <int>{};
      final auth = <String?>[];
      server.listen((req) async {
        ports.add(req.connectionInfo!.remotePort);
        auth.add(req.headers.value('Authorization'));
        req.response.add(_png);
        await req.response.close();
      });
      try {
        final url = 'http://127.0.0.1:${server.port}/same.png';
        await _load(CachedNetImage(url, headers: const {'Authorization': 'first'}));
        await _load(CachedNetImage(url, headers: const {'Authorization': 'second'}));
        expect(auth, ['first', 'second']);
        expect(ports.length, 1);
        expect(CachedNetImage(url), CachedNetImage(url));
      } finally {
        await server.close(force: true);
      }
    });
  });

  testWidgets('TV 图片下载并发最多四个，余下图片排队后继续完成', (tester) async {
    await tester.runAsync(() async {
      HttpOverrides.global = null;
      CachedNetImage.configure(tv: true);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      final fourStarted = Completer<void>();
      var requests = 0;
      var active = 0;
      var peak = 0;
      server.listen((req) async {
        requests++;
        active++;
        if (active > peak) peak = active;
        if (requests == 4) fourStarted.complete();
        await release.future;
        req.response.add(_png);
        await req.response.close();
        active--;
      });
      try {
        final loads = Future.wait([
          for (var i = 0; i < 7; i++) _load(CachedNetImage('http://127.0.0.1:${server.port}/$i.png')),
        ]);
        await fourStarted.future.timeout(const Duration(seconds: 5));
        expect(requests, 4);
        expect(CachedNetImage.activeDownloads, 4);
        expect(CachedNetImage.queuedDownloads, 3);
        release.complete();
        await loads;
        expect(requests, 7);
        expect(peak, lessThanOrEqualTo(4));
      } finally {
        if (!release.isCompleted) release.complete();
        await server.close(force: true);
        CachedNetImage.configure(tv: false);
      }
    });
  });

  testWidgets('响应体超时会取消连接，四个失败请求不会堵住后续图片', (tester) async {
    await tester.runAsync(() async {
      HttpOverrides.global = null;
      CachedNetImage.configure(tv: true);
      CachedNetImage.resetNetworkForTesting(timeout: const Duration(milliseconds: 300));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      server.listen((req) async {
        try {
          if (req.uri.path.startsWith('/slow')) {
            req.response.add(_png.take(8).toList());
            await req.response.flush();
            await release.future;
          } else {
            req.response.add(_png);
          }
          await req.response.close();
        } catch (_) {
          // The client deliberately closes timed-out response bodies.
        }
      });
      try {
        await Future.wait([
          for (var i = 0; i < 4; i++)
            expectLater(
              _load(CachedNetImage('http://127.0.0.1:${server.port}/slow$i')),
              throwsA(isA<TimeoutException>()),
            ),
        ]);
        final info = await _load(CachedNetImage('http://127.0.0.1:${server.port}/ok.png'));
        expect(info.image.width, 1);
        expect(CachedNetImage.activeDownloads, 0);
      } finally {
        release.complete();
        await server.close(force: true);
        CachedNetImage.resetNetworkForTesting();
        CachedNetImage.configure(tv: false);
      }
    });
  });
}
