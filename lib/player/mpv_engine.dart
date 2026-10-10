import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'engine.dart';

/// mpv 内核（media_kit）。Windows 默认；Android 作为 ExoPlayer 的备用。
class MpvEngine extends PlayerEngine {
  MpvEngine() {
    final s = _player.stream;
    _subs.addAll([
      s.position.listen((v) => _set((x) => x.copyWith(position: v))),
      s.duration.listen((v) => _set((x) => x.copyWith(duration: v))),
      s.buffer.listen((v) => _set((x) => x.copyWith(buffered: v))),
      s.playing.listen((v) => _set((x) => x.copyWith(playing: v))),
      s.buffering.listen((v) => _set((x) => x.copyWith(buffering: v))),
      s.rate.listen((v) => _set((x) => x.copyWith(rate: v))),
      s.tracks.listen(
        (t) => _set(
          (x) => x.copyWith(
            audioTracks: [
              for (final a in t.audio)
                if (_real(a.id)) _audio(a),
            ],
            subtitleTracks: [
              for (final a in t.subtitle)
                if (_real(a.id)) _sub(a),
            ],
          ),
        ),
      ),
      s.track.listen(
        (t) => _set(
          (x) => x.copyWith(
            audio: _real(t.audio.id) ? _audio(t.audio) : null,
            subtitle: _real(t.subtitle.id) ? _sub(t.subtitle) : null,
            clearSubtitle: !_real(t.subtitle.id),
          ),
        ),
      ),
      s.videoParams.listen(
        (p) => _set(
          (x) => x.copyWith(
            video: EngineVideoInfo(
              width: p.dw ?? p.w,
              height: p.dh ?? p.h,
              hdr: switch (p.gamma) {
                'pq' => 'HDR10',
                'hlg' => 'HLG',
                _ => null,
              },
              codec: x.video.codec,
            ),
          ),
        ),
      ),
      s.completed.listen((done) {
        if (done) _completed.add(null);
      }),
      s.error.listen((e) => _errors.add(EngineError(e, canFallback: false))),
    ]);
  }

  final Player _player = Player(
    configuration: const PlayerConfiguration(title: 'Viora', bufferSize: 64 * 1024 * 1024),
  );
  late final VideoController _video = VideoController(_player);
  final _state = ValueNotifier(const EngineState());
  final _completed = StreamController<void>.broadcast();
  final _errors = StreamController<EngineError>.broadcast();
  final _subs = <StreamSubscription<Object?>>[];

  static bool _real(String id) => id != 'auto' && id != 'no';

  static EngineTrack _audio(AudioTrack t) => EngineTrack(
    id: t.id,
    title: t.title,
    language: t.language,
    codec: t.codec,
    channels: t.channelscount,
    external: t.uri,
  );

  static EngineTrack _sub(SubtitleTrack t) =>
      EngineTrack(id: t.id, title: t.title, language: t.language, codec: t.codec, external: t.uri);

  void _set(EngineState Function(EngineState) f) => _state.value = f(_state.value);

  @override
  EngineKind get kind => EngineKind.mpv;

  @override
  ValueListenable<EngineState> get state => _state;

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Stream<EngineError> get errors => _errors.stream;

  @override
  Future<void> open(EngineMedia media) async {
    final native = _player.platform;
    if (!kIsWeb && native is NativePlayer) {
      // 自定义播放 UA（docs/03-media-servers.md §6），其余请求头由 httpHeaders 传入
      await (native as dynamic).setProperty('user-agent', media.userAgent);
      await (native as dynamic).setProperty('network-timeout', '20');
      await (native as dynamic).setProperty('demuxer-max-back-bytes', '${32 * 1024 * 1024}');
    }
    await _player.open(
      Media(media.url.toString(), httpHeaders: media.headers, start: media.start > Duration.zero ? media.start : null),
    );
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Future<void> selectAudio(EngineTrack track) async {
    final t = _player.state.tracks.audio.where((a) => a.id == track.id).firstOrNull;
    if (t != null) await _player.setAudioTrack(t);
  }

  @override
  Future<void> selectSubtitle(EngineTrack? track) async {
    if (track == null) return _player.setSubtitleTrack(SubtitleTrack.no());
    final t = _player.state.tracks.subtitle.where((a) => a.id == track.id).firstOrNull;
    if (t != null) await _player.setSubtitleTrack(t);
  }

  @override
  Future<void> addExternalSubtitle(Uri url, {String? title, String? language}) =>
      _player.setSubtitleTrack(SubtitleTrack.uri(url.toString(), title: title, language: language));

  @override
  Widget buildView() => Video(controller: _video, controls: NoVideoControls, fill: Colors.black);

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _completed.close();
    await _errors.close();
    await _player.dispose();
    _state.dispose();
  }
}
