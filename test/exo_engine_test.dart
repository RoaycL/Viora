import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/player/engine.dart';
import 'package:viora/player/exo_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ExoEngine：方法调用参数与事件映射', () async {
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('viora/exo'), (call) async {
      calls.add(call);
      return call.method == 'create' ? 7 : null;
    });
    late MockStreamHandlerEventSink sink;
    final listening = Completer<void>();
    messenger.setMockStreamHandler(
      const EventChannel('viora/exo/events'),
      MockStreamHandler.inline(
        onListen: (args, events) {
          sink = events;
          listening.complete();
        },
      ),
    );

    final engine = ExoEngine(options: const EngineOptions(autoFrameRate: true, tunneling: false));
    final errors = <EngineError>[];
    engine.errors.listen(errors.add);
    var completed = 0;
    engine.completed.listen((_) => completed++);

    await engine.open(
      EngineMedia(
        url: Uri.parse('https://emby.a.com/Videos/1/stream.mkv'),
        headers: const {'X-Emby-Token': 't'},
        userAgent: 'UA/1',
        start: const Duration(seconds: 90),
      ),
    );
    await listening.future;

    final open = calls.firstWhere((c) => c.method == 'open');
    final args = open.arguments as Map;
    expect(args['id'], 7);
    expect(args['userAgent'], 'UA/1');
    expect(args['startMs'], 90000);
    expect(args['frameRateSwitch'], isTrue);
    expect((args['headers'] as Map)['X-Emby-Token'], 't');

    // 其他播放器的事件被忽略
    sink.success({'id': 8, 'event': 'playing', 'playing': true});
    sink.success({'id': 7, 'event': 'progress', 'position': 5000, 'duration': 600000, 'buffered': 9000});
    sink.success({'id': 7, 'event': 'playing', 'playing': true});
    sink.success({
      'id': 7,
      'event': 'tracks',
      'audio': [
        {'id': '1:0', 'language': 'zh', 'codec': 'eac3', 'channels': 6, 'selected': true},
        {'id': '1:1', 'language': 'en', 'codec': 'aac', 'channels': 2, 'selected': false},
      ],
      'subtitle': [
        {'id': '2:0', 'title': '简体中文', 'selected': false},
      ],
    });
    sink.success({'id': 7, 'event': 'video', 'width': 3840, 'height': 2160, 'frameRate': 23.976, 'hdr': 'HDR10'});
    sink.success({'id': 7, 'event': 'error', 'message': 'ERROR_CODE_DECODER_INIT_FAILED', 'fallback': true});
    sink.success({'id': 7, 'event': 'completed'});
    await Future<void>.delayed(Duration.zero);

    final s = engine.state.value;
    expect(s.position, const Duration(seconds: 5));
    expect(s.duration, const Duration(minutes: 10));
    expect(s.playing, isTrue);
    expect(s.audioTracks.length, 2);
    expect(s.audio?.id, '1:0');
    expect(s.audio?.displayName, 'zh · EAC3 · 5.1');
    expect(s.subtitle, isNull);
    expect(s.video.hdr, 'HDR10');
    expect(errors.single.canFallback, isTrue);
    expect(completed, 1);

    await engine.selectSubtitle(s.subtitleTracks.first);
    await engine.selectSubtitle(null);
    final selects = calls.where((c) => c.method == 'selectTrack').map((c) => (c.arguments as Map)['track']).toList();
    expect(selects, ['2:0', null]);

    await engine.dispose();
    expect(calls.last.method, 'dispose');
  });
}
