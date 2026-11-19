import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../app/desktop_prefs.dart';
import '../app/platform_profile.dart';
import 'engine.dart';
import 'playback_cache.dart';

/// mpv 内核（media_kit）。Windows 默认；Android 作为 ExoPlayer 的备用。
class MpvEngine extends PlayerEngine {
  /// 电视上 mpv 缓冲的上限（字节）
  static const tvBufferLimit = 96 * 1024 * 1024;

  MpvEngine({this.options = const EngineOptions()}) {
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
    // 下载速度：mpv 的 cache-speed（字节 / 秒），每秒读一次
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollSpeed());
  }

  Timer? _speedTimer;
  bool _disposed = false;

  Future<void> _pollSpeed() async {
    final native = _player.platform;
    if (kIsWeb || native is! NativePlayer || _state.value.duration == Duration.zero) return;
    try {
      final raw = await (native as dynamic).getProperty('cache-speed') as String;
      final v = int.tryParse(raw.split('.').first);
      if (v != null && !_disposed) _set((x) => x.copyWith(speed: v));
    } catch (_) {}
  }

  final EngineOptions options;

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
      // 单个属性设置失败（旧版 libmpv 不支持等）不影响播放
      Future<void> set(String name, String value) async {
        try {
          await (native as dynamic).setProperty(name, value);
        } catch (e) {
          debugPrint('mpv $name=$value failed: $e');
        }
      }

      // 自定义播放 UA（docs/03-media-servers.md §6），其余请求头由 httpHeaders 传入
      await set('user-agent', media.userAgent);
      // 跟随系统代理（设置 → 接口与网络）：播放也走代理；局域网地址直连
      // 每次开始播放前重新读系统代理：启动后才打开 / 关掉 Clash 时不会连到已经失效的代理
      await SystemProxy.refresh();
      await set('http-proxy', SystemProxy.forMpv(media.url) ?? '');
      await set('network-timeout', '20');
      // 预读缓冲上限（设置 → 播放 → 播放缓冲上限）；超过内存上限时写到磁盘缓存，关闭播放器后清除
      // 电视（ExoPlayer 放不了的格式才会用到 mpv，多是高码率原盘）：缓冲全在内存里，封顶 96MB、回看 16MB，
      // 不然 2GB 的盒子上 256MB + 64MB 足以把内存吃满被系统杀掉
      final tv = PlatformProfile.isTv;
      final buffer = tv ? options.bufferBytes.clamp(0, tvBufferLimit) : options.bufferBytes;
      final onDisk = buffer > PlaybackCache.memoryLimitBytes && options.cacheDir != null;
      await set('cache', 'yes');
      await set('demuxer-max-bytes', '$buffer');
      await set('demuxer-max-back-bytes', '${tv ? 16 << 20 : (buffer ~/ 4).clamp(16 << 20, 128 << 20)}');
      if (onDisk) await set('cache-dir', options.cacheDir!);
      await set('cache-on-disk', onDisk ? 'yes' : 'no');
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

  Future<void> _prop(String name, String value) async {
    final native = _player.platform;
    if (native == null) return;
    try {
      await (native as dynamic).setProperty(name, value);
    } catch (e) {
      debugPrint('mpv $name=$value failed: $e');
    }
  }

  @override
  bool get supportsSubtitleDelay => true;

  @override
  Future<void> setSubtitleDelay(Duration delay) => _prop('sub-delay', (delay.inMilliseconds / 1000).toStringAsFixed(3));

  // media_kit 默认不让 mpv 自己画字幕（sub-visibility=no），字幕文字由 Flutter 画在画面上，
  // 所以 mpv 的 sub-scale / sub-pos 不起作用；大小和位置在这里自己处理（内封和外挂字幕都一样）
  final _subScale = ValueNotifier(1.0);
  final _subPos = ValueNotifier(100);

  @override
  Future<void> setSubtitleScale(double scale) async => _subScale.value = scale;

  @override
  bool get supportsSubtitlePosition => true;

  @override
  Future<void> setSubtitlePosition(int position) async => _subPos.value = position;

  final _fit = ValueNotifier(VideoFit.contain);

  @override
  Future<void> setVideoFit(VideoFit fit) async => _fit.value = fit;

  @override
  Future<void> setVolume(double volume) => _player.setVolume((volume * 100).clamp(0, 100).toDouble());

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
  Widget buildView() => Stack(
    fit: StackFit.expand,
    children: [
      ValueListenableBuilder<VideoFit>(
        valueListenable: _fit,
        builder: (context, fit, _) => Video(
          controller: _video,
          controls: NoVideoControls,
          subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
          fill: Colors.black,
          fit: switch (fit) {
            VideoFit.contain => BoxFit.contain,
            VideoFit.cover => BoxFit.cover,
            VideoFit.fill => BoxFit.fill,
          },
        ),
      ),
      MpvSubtitleView(player: _player, scale: _subScale, position: _subPos),
    ],
  );

  @override
  Future<void> dispose() async {
    _disposed = true;
    _speedTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    await _completed.close();
    await _errors.close();
    await _player.dispose();
    _state.dispose();
    _fit.dispose();
    _subScale.dispose();
    _subPos.dispose();
  }
}

/// mpv 内核的字幕：文字来自 mpv（sub-text，已按字幕延迟对齐），大小和上下位置跟随播放设置
class MpvSubtitleView extends StatefulWidget {
  const MpvSubtitleView({super.key, required this.player, required this.scale, required this.position});

  final Player player;

  /// 字幕大小倍数（1 = 标准）
  final ValueListenable<double> scale;

  /// 和 mpv 的 sub-pos 同义：100 = 默认的底部，数值越小越靠上（每 1 = 画面高度的 1%），最大 150
  final ValueListenable<int> position;

  /// 1080p 画面上标准大小的字号
  static const baseFontSize = 32.0;

  /// 默认位置离画面底部的距离（1080p）
  static const baseBottom = 24.0;

  /// 跟 media_kit 原来的字幕一样按画面面积缩放（以 1080p 为准）
  static double _k(Size size) => math.sqrt((size.width * size.height / (1920 * 1080)).clamp(0.0, 1.0));

  /// 字幕最后一行底边离画面底部的距离（「字幕位置」调整时的预览框用同一个算法，位置完全对得上）
  static double bottomOffset(Size size, int position) =>
      (baseBottom * _k(size) + (100 - position) / 100 * size.height).clamp(0.0, size.height * 0.9);

  /// 字号：按画面面积缩放，再乘上字幕大小设置
  static double fontSize(Size size, double scale) => baseFontSize * _k(size) * scale;

  @override
  State<MpvSubtitleView> createState() => _MpvSubtitleViewState();
}

class _MpvSubtitleViewState extends State<MpvSubtitleView> {
  late List<String> _lines = widget.player.state.subtitle;
  StreamSubscription<List<String>>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.player.stream.subtitle.listen((v) {
      if (mounted) setState(() => _lines = v);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = [
      for (final l in _lines)
        if (l.trim().isNotEmpty) l.trim(),
    ].join('\n');
    if (text.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, c) => ListenableBuilder(
          listenable: Listenable.merge([widget.scale, widget.position]),
          builder: (context, _) {
            // 跟 media_kit 原来的字幕一样按画面面积缩放（以 1080p 为准），再乘上字幕大小设置
            final size = c.biggest;
            final bottom = MpvSubtitleView.bottomOffset(size, widget.position.value);
            return Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, bottom),
              child: Align(
                alignment: Alignment.bottomCenter,
                // 不要黑底色块：白字 + 细黑描边 + 柔和阴影，直接叠在画面上（和主流播放器一样）
                child: _OutlinedSubtitle(text: text, fontSize: MpvSubtitleView.fontSize(size, widget.scale.value)),
              ),
            );
          },
        ),
      ),
    );
  }
}


/// 字幕文字：白字、黑色描边、柔和阴影（深色、浅色画面上都看得清，又不遮住画面）
class _OutlinedSubtitle extends StatelessWidget {
  const _OutlinedSubtitle({required this.text, required this.fontSize});

  final String text;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: fontSize, height: 1.3, fontWeight: FontWeight.w500, letterSpacing: 0.5);
    return Stack(
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          textScaler: TextScaler.noScaling,
          style: style.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = (fontSize * 0.1).clamp(1.5, 5.0)
              ..strokeJoin = StrokeJoin.round
              ..color = const Color(0xE6000000),
            shadows: [Shadow(color: const Color(0x99000000), blurRadius: fontSize * 0.3, offset: Offset(0, fontSize * 0.05))],
          ),
        ),
        Text(text, textAlign: TextAlign.center, textScaler: TextScaler.noScaling, style: style.copyWith(color: Colors.white)),
      ],
    );
  }
}
