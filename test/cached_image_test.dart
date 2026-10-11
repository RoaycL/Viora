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
  provider
      .resolve(ImageConfiguration.empty)
      .addListener(
        ImageStreamListener(
          (info, _) => done.isCompleted ? null : done.complete(info),
          onError: (e, _) => done.isCompleted ? null : done.completeError(e),
        ),
      );
  return done.future.timeout(const Duration(seconds: 10));
}

void main() {
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
}
