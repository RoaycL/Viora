import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'engine.dart';

/// ExoPlayer（Media3）内核，仅 Android。原生实现见 android/app/src/main/kotlin/com/viora/viora/exo/。
///
/// 画面用 PlatformView（Hybrid Composition）嵌入 SurfaceView，HDR10 / 杜比视界可以直通到电视。
class ExoEngine extends PlayerEngine {
  ExoEngine({this.options = const EngineOptions()});

  static const _channel = MethodChannel('viora/exo');
  static const _events = EventChannel('viora/exo/events');
  static Stream<Map<Object?, Object?>>? _eventStream;

  final EngineOptions options;
  final _state = ValueNotifier(const EngineState());
  final _completed = StreamController<void>.broadcast();
  final _errors = StreamController<EngineError>.broadcast();
  final _idReady = Completer<int>();
  StreamSubscription<Map<Object?, Object?>>? _sub;
  int? _id;
  bool _disposed = false;

  /// 是否运行在支持 ExoPlayer 的平台上
  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<int> _ensureCreated() async {
    if (_id != null) return _id!;
    _eventStream ??= _events.receiveBroadcastStream().cast<Map<Object?, Object?>>();
    _sub = _eventStream!.listen((e) {
      if (e['id'] == _id) _onEvent(e);
    });
    final id = await _channel.invokeMethod<int>('create', {'bufferBytes': options.bufferBytes});
    _id = id;
    _idReady.complete(id!);
    return id;
  }

  Future<void> _call(String method, [Map<String, Object?> args = const {}]) async {
    if (_disposed) return;
    final id = await _ensureCreated();
    await _channel.invokeMethod<void>(method, {'id': id, ...args});
  }

  void _set(EngineState Function(EngineState) f) {
    if (!_disposed) _state.value = f(_state.value);
  }

  static Duration _ms(Object? v) => Duration(milliseconds: (v as num? ?? 0).toInt());

  EngineTrack _track(Map<Object?, Object?> m) => EngineTrack(
    id: m['id']! as String,
    title: m['title'] as String?,
    language: m['language'] as String?,
    codec: m['codec'] as String?,
    channels: m['channels'] as int?,
  );

  void _onEvent(Map<Object?, Object?> e) {
    switch (e['event']) {
      case 'progress':
        _set(
          (s) => s.copyWith(
            position: _ms(e['position']),
            duration: e['duration'] == null ? s.duration : _ms(e['duration']),
            buffered: _ms(e['buffered']),
            speed: (e['speed'] as num?)?.toInt(),
          ),
        );
      case 'state':
        _set((s) => s.copyWith(buffering: e['buffering'] == true));
      case 'playing':
        _set((s) => s.copyWith(playing: e['playing'] == true));
      case 'rate':
        _set((s) => s.copyWith(rate: (e['rate'] as num?)?.toDouble() ?? 1));
      case 'completed':
        _completed.add(null);
      case 'tracks':
        final audio = [for (final m in (e['audio'] as List? ?? const [])) m as Map<Object?, Object?>];
        final subs = [for (final m in (e['subtitle'] as List? ?? const [])) m as Map<Object?, Object?>];
        final selectedAudio = audio.where((m) => m['selected'] == true).firstOrNull;
        final selectedSub = subs.where((m) => m['selected'] == true).firstOrNull;
        _set(
          (s) => s.copyWith(
            audioTracks: [for (final m in audio) _track(m)],
            subtitleTracks: [for (final m in subs) _track(m)],
            audio: selectedAudio == null ? null : _track(selectedAudio),
            subtitle: selectedSub == null ? null : _track(selectedSub),
            clearSubtitle: selectedSub == null,
          ),
        );
      case 'video':
        _set(
          (s) => s.copyWith(
            video: EngineVideoInfo(
              width: e['width'] as int?,
              height: e['height'] as int?,
              frameRate: (e['frameRate'] as num?)?.toDouble(),
              codec: e['codec'] as String?,
              hdr: e['hdr'] as String?,
              decoder: e['decoder'] as String?,
            ),
          ),
        );
      case 'error':
        _errors.add(EngineError(e['message'] as String? ?? '播放失败', canFallback: e['fallback'] == true));
    }
  }

  @override
  EngineKind get kind => EngineKind.exo;

  @override
  ValueListenable<EngineState> get state => _state;

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Stream<EngineError> get errors => _errors.stream;

  @override
  Future<void> open(EngineMedia media) => _call('open', {
    'url': media.url.toString(),
    'headers': media.headers,
    'userAgent': media.userAgent,
    'startMs': media.start.inMilliseconds,
    'tunneling': options.tunneling,
    'frameRateSwitch': options.autoFrameRate,
  });

  @override
  Future<void> play() => _call('play');

  @override
  Future<void> pause() => _call('pause');

  @override
  Future<void> seek(Duration position) => _call('seek', {'ms': position.inMilliseconds});

  @override
  Future<void> setRate(double rate) => _call('setRate', {'rate': rate});

  @override
  Future<void> selectAudio(EngineTrack track) => _call('selectTrack', {'type': 'audio', 'track': track.id});

  @override
  Future<void> selectSubtitle(EngineTrack? track) => _call('selectTrack', {'type': 'text', 'track': track?.id});

  @override
  Future<void> addExternalSubtitle(Uri url, {String? title, String? language}) =>
      _call('addSubtitle', {'url': url.toString(), 'title': title, 'language': language});

  @override
  Widget buildView() => FutureBuilder<int>(
    future: _idReady.future,
    builder: (context, snap) =>
        snap.hasData ? _ExoView(playerId: snap.data!) : const ColoredBox(color: Color(0xFF000000)),
  );

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _sub?.cancel();
    if (_id != null) await _channel.invokeMethod<void>('dispose', {'id': _id});
    await _completed.close();
    await _errors.close();
    _state.dispose();
  }
}

/// Hybrid Composition 的 PlatformView：原生 SurfaceView 真正参与窗口合成，HDR 才能直通。
class _ExoView extends StatelessWidget {
  const _ExoView({required this.playerId});

  final int playerId;

  static const _viewType = 'viora/exo-view';

  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(
      viewType: _viewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      ),
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: _viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: {'id': playerId},
          creationParamsCodec: const StandardMessageCodec(),
        );
        controller
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
        return controller;
      },
    );
  }
}
