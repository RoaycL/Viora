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
      s.videoParams.listen((p) {
        _fitTexture(p);
        _set(
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
              decoder: x.video.decoder,
            ),
          ),
        );
      }),
      s.completed.listen((done) {
        if (done) _completed.add(null);
      }),
      s.error.listen((e) => _errors.add(EngineError(e, canFallback: false))),
    ]);
    // 读系统代理要起一个 reg 进程（Windows 上几十到几百毫秒）：创建内核时就开始读，和取播放信息同时进行，
    // 不占起播时间。open 时用这次的结果，之后再打开（换源、换集）照常重新读
    _pendingProxy = SystemProxy.refresh()..ignore();
    // 下载速度：mpv 的 cache-speed（字节 / 秒），每秒读一次
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollSpeed());
  }

  Timer? _speedTimer;
  bool _disposed = false;
  Future<void>? _pendingProxy;

  /// 桌面端画面纹理的固定大小；null = 跟片源分辨率一样（media_kit 默认）
  (int, int)? _textureSize;

  /// 桌面端：片源分辨率比屏幕大时（如 1080p / 2K 屏幕看 4K），让 mpv 直接按屏幕分辨率出画面。
  /// media_kit 默认按片源分辨率建纹理：4K 片子每帧都要在 4K 上做缩放、HDR 色调映射，再交给 Flutter 缩小一次，
  /// 显卡负担是 1080p 的 4 倍。按屏幕大小输出后画质不变（本来也要缩小到屏幕大小），GPU 占用明显下降，掉帧更少
  void _fitTexture(VideoParams p) {
    if (!PlatformProfile.isDesktop || _disposed) return;
    final dw = p.dw ?? p.w, dh = p.dh ?? p.h;
    if (dw == null || dh == null || dw <= 0 || dh <= 0) return;
    // 旋转 90° / 270° 的片源（竖拍视频）宽高互换，和 media_kit 默认按片源建纹理时一样
    final rotated = p.rotate == 90 || p.rotate == 270;
    final w = rotated ? dh : dw, h = rotated ? dw : dh;
    final displays = WidgetsBinding.instance.platformDispatcher.displays;
    if (displays.isEmpty) return;
    // 多显示器取最大的一块：窗口拖到 4K 屏上也不会糊
    var screen = Size.zero;
    for (final d in displays) {
      screen = Size(math.max(screen.width, d.size.width), math.max(screen.height, d.size.height));
    }
    final target = textureSizeFor(w, h, screen);
    if (target == _textureSize) return;
    _textureSize = target;
    unawaited(
      _video.setSize(width: target?.$1, height: target?.$2).catchError((Object e) => debugPrint('mpv setSize: $e')),
    );
  }

  /// 片源 [width]×[height] 在 [screen]（物理像素）上需要的纹理大小：保持比例，按「填满」铺满屏幕所需的大小缩小，
  /// 这样「适应」「填满」两种画面比例都不会被放大；片源本来就不比屏幕大时返回 null（不限制）
  @visibleForTesting
  static (int, int)? textureSizeFor(int width, int height, Size screen) {
    if (screen.width <= 0 || screen.height <= 0) return null;
    final scale = math.max(screen.width / width, screen.height / height);
    if (scale >= 1) return null;
    int even(double v) => math.max(2, (v / 2).round() * 2);
    return (even(width * scale), even(height * scale));
  }

  Future<void> _pollSpeed() async {
    final native = _player.platform;
    if (kIsWeb || native is! NativePlayer || _state.value.duration == Duration.zero) return;
    Future<String?> get(String name) async {
      try {
        return await (native as dynamic).getProperty(name) as String;
      } catch (_) {
        return null;
      }
    }

    final v = int.tryParse((await get('cache-speed'))?.split('.').first ?? '');
    // 播放统计：实际用的硬解方式（no = 软解）和丢帧数（解码器丢的 + 显示时丢的）
    final hwdec = await get('hwdec-current');
    final dropped = [
      int.tryParse(await get('frame-drop-count') ?? ''),
      int.tryParse(await get('decoder-frame-drop-count') ?? ''),
    ].nonNulls.fold<int?>(null, (a, b) => (a ?? 0) + b);
    if (_disposed) return;
    final decoder = hwdec == null || hwdec.isEmpty ? null : mpvDecoderLabel(hwdec);
    _set(
      (x) => x.copyWith(
        speed: v,
        droppedFrames: dropped,
        video: decoder == null || decoder == x.video.decoder
            ? null
            : EngineVideoInfo(
                width: x.video.width,
                height: x.video.height,
                frameRate: x.video.frameRate,
                codec: x.video.codec,
                hdr: x.video.hdr,
                decoder: decoder,
              ),
      ),
    );
  }

  final EngineOptions options;

  /// mpv 的 hwdec-current 换成媒体信息里显示的解码方式
  @visibleForTesting
  static String mpvDecoderLabel(String hwdec) => hwdec == 'no' ? '软解（CPU）' : '硬解 · $hwdec';

  final Player _player = Player(
    configuration: const PlayerConfiguration(title: 'Viora', bufferSize: 64 * 1024 * 1024),
  );
  // 软解时直接用 hwdec=no 建画面输出（media_kit 在建输出时设 hwdec，之后再改也可以，但起播就是软解更干净）
  late final VideoController _video = VideoController(
    _player,
    configuration: VideoControllerConfiguration(hwdec: options.hardwareDecoding ? null : 'no'),
  );
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
      final proxy = _pendingProxy ?? SystemProxy.refresh();
      _pendingProxy = null;
      await proxy;
      await set('http-proxy', SystemProxy.forMpv(media.url) ?? '');
      await set('network-timeout', '20');
      // media_kit 默认 hr-seek-framedrop=no：精确跳转（续播、拖动进度、跳片头）时，从关键帧到目标位置之间的每一帧
      // 都要完整解码并输出。4K HEVC 关键帧间隔常有 5~10 秒，跳一次要多等一两秒。改回 mpv 的默认 yes：
      // 目标位置之前的帧解码后直接丢掉，落点一样准，续播起播和拖动明显更快（我们不用会改时间戳的视频滤镜）
      await set('hr-seek-framedrop', 'yes');
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
  bool get supportsDecoderSwitch => true;

  // 硬解用回 media_kit 的默认值（Windows auto，Android auto-safe）
  @override
  Future<void> setHardwareDecoding(bool enabled) =>
      _prop('hwdec', enabled ? (defaultTargetPlatform == TargetPlatform.android ? 'auto-safe' : 'auto') : 'no');

  @override
  Future<void> setSubtitleBrightness(double brightness) async => _subBrightness.value = brightness.clamp(0.2, 1.0);

  @override
  bool get supportsAudioDelay => true;

  // mpv 的 audio-delay：正数 = 声音推后
  @override
  Future<void> setAudioDelay(Duration delay) => _prop('audio-delay', (delay.inMilliseconds / 1000).toStringAsFixed(3));

  @override
  Future<void> setSubtitleDelay(Duration delay) => _prop('sub-delay', (delay.inMilliseconds / 1000).toStringAsFixed(3));

  // media_kit 默认不让 mpv 自己画字幕（sub-visibility=no），字幕文字由 Flutter 画在画面上，
  // 所以 mpv 的 sub-scale / sub-pos 不起作用；大小和位置在这里自己处理（内封和外挂字幕都一样）
  final _subScale = ValueNotifier(1.0);
  final _subPos = ValueNotifier(100);
  final _subBrightness = ValueNotifier(1.0);

  @override
  Future<void> setSubtitleScale(double scale) async => _subScale.value = scale;

  @override
  bool get supportsSubtitlePosition => true;

  @override
  Future<void> setSubtitlePosition(int position) async => _subPos.value = position;

  // cache-secs：开了缓存时往后预读的秒数（mpv 默认极大，实际由 demuxer-max-bytes 限制）
  @override
  Future<void> setReadaheadLimit(Duration? limit) => _prop(
    'cache-secs',
    limit == null ? '3600000' : (limit.inMilliseconds / 1000).clamp(1, 3600000).toStringAsFixed(1),
  );

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
      MpvSubtitleView(player: _player, scale: _subScale, position: _subPos, brightness: _subBrightness),
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
    _subBrightness.dispose();
  }
}

/// mpv 内核的字幕：文字来自 mpv（sub-text，已按字幕延迟对齐），大小和上下位置跟随播放设置
class MpvSubtitleView extends StatefulWidget {
  const MpvSubtitleView({
    super.key,
    required this.player,
    required this.scale,
    required this.position,
    this.brightness,
  });

  final Player player;

  /// 字幕亮度（1 = 白色；HDR 片源上调暗）
  final ValueListenable<double>? brightness;

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
          listenable: Listenable.merge([widget.scale, widget.position, ?widget.brightness]),
          builder: (context, _) {
            // 跟 media_kit 原来的字幕一样按画面面积缩放（以 1080p 为准），再乘上字幕大小设置
            final size = c.biggest;
            final bottom = MpvSubtitleView.bottomOffset(size, widget.position.value);
            return Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, bottom),
              child: Align(
                alignment: Alignment.bottomCenter,
                // 不要黑底色块：白字 + 细黑描边 + 柔和阴影，直接叠在画面上（和主流播放器一样）
                child: _OutlinedSubtitle(
                  text: text,
                  fontSize: MpvSubtitleView.fontSize(size, widget.scale.value),
                  brightness: widget.brightness?.value ?? 1,
                ),
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
  const _OutlinedSubtitle({required this.text, required this.fontSize, this.brightness = 1});

  final String text;
  final double fontSize;
  final double brightness;

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
            shadows: [
              Shadow(color: const Color(0x99000000), blurRadius: fontSize * 0.3, offset: Offset(0, fontSize * 0.05)),
            ],
          ),
        ),
        Text(
          text,
          textAlign: TextAlign.center,
          textScaler: TextScaler.noScaling,
          style: style.copyWith(color: Color.lerp(Colors.black, Colors.white, brightness)),
        ),
      ],
    );
  }
}
