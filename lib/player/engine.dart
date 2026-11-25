import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 播放内核（docs/08-player.md §2）：mpv（Windows / Android 备用）与 ExoPlayer（Android TV 默认）。
enum EngineKind {
  mpv('mpv'),
  exo('ExoPlayer');

  const EngineKind(this.label);
  final String label;
}

/// 音轨 / 字幕轨
@immutable
class EngineTrack {
  const EngineTrack({required this.id, this.title, this.language, this.codec, this.channels, this.external = false});

  /// 内核内部的轨道 ID（mpv 为 track id；ExoPlayer 为 "组序号:轨道序号"）
  final String id;
  final String? title;
  final String? language;
  final String? codec;
  final int? channels;
  final bool external;

  String get displayName {
    final parts = <String>[
      if (title != null && title!.isNotEmpty) title!,
      if (language != null && language!.isNotEmpty && language != 'und') language!,
      if (codec != null && codec!.isNotEmpty) codec!.toUpperCase(),
      if (channels != null && channels! > 0) channels! >= 6 ? '${channels! - 1}.1' : '$channels.0',
    ];
    return parts.isEmpty ? '轨道 $id' : parts.join(' · ');
  }

  /// 文字字幕（SRT / ASS / WebVTT 等）；PGS、VobSub、DVB 是图片字幕
  bool get isTextSubtitle {
    final c = codec?.toLowerCase() ?? '';
    return !const {
      'hdmv_pgs_subtitle',
      'pgs',
      'pgssub',
      'dvd_subtitle',
      'dvdsub',
      'vobsub',
      'dvb_subtitle',
      'dvbsub',
      'xsub',
    }.contains(c);
  }

  @override
  bool operator ==(Object other) => other is EngineTrack && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 实际在播的视频信息（OSD 与媒体信息叠加层用）
@immutable
class EngineVideoInfo {
  const EngineVideoInfo({this.width, this.height, this.frameRate, this.codec, this.hdr, this.decoder});

  final int? width;
  final int? height;
  final double? frameRate;
  final String? codec;

  /// HDR10 / HLG / Dolby Vision；SDR 时为 null
  final String? hdr;
  final String? decoder;
}

@immutable
class EngineState {
  const EngineState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffered = Duration.zero,
    this.playing = false,
    this.buffering = true,
    this.rate = 1,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
    this.audio,
    this.subtitle,
    this.video = const EngineVideoInfo(),
    this.speed,
    this.droppedFrames,
  });

  /// 当前下载速度（字节 / 秒）；null = 内核不提供
  final int? speed;

  /// 这次打开以来丢掉的视频帧数（播放统计）；null = 内核不提供
  final int? droppedFrames;

  final Duration position;
  final Duration duration;
  final Duration buffered;
  final bool playing;
  final bool buffering;
  final double rate;
  final List<EngineTrack> audioTracks;
  final List<EngineTrack> subtitleTracks;
  final EngineTrack? audio;

  /// null = 字幕关闭
  final EngineTrack? subtitle;
  final EngineVideoInfo video;

  EngineState copyWith({
    Duration? position,
    Duration? duration,
    Duration? buffered,
    bool? playing,
    bool? buffering,
    double? rate,
    List<EngineTrack>? audioTracks,
    List<EngineTrack>? subtitleTracks,
    EngineTrack? audio,
    EngineTrack? subtitle,
    bool clearSubtitle = false,
    EngineVideoInfo? video,
    int? speed,
    int? droppedFrames,
  }) => EngineState(
    position: position ?? this.position,
    duration: duration ?? this.duration,
    buffered: buffered ?? this.buffered,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    rate: rate ?? this.rate,
    audioTracks: audioTracks ?? this.audioTracks,
    subtitleTracks: subtitleTracks ?? this.subtitleTracks,
    audio: audio ?? this.audio,
    subtitle: clearSubtitle ? null : (subtitle ?? this.subtitle),
    video: video ?? this.video,
    speed: speed ?? this.speed,
    droppedFrames: droppedFrames ?? this.droppedFrames,
  );
}

/// 播放错误。[canFallback] = 换另一个内核可能解决（解码 / 格式不支持），网络错误为 false。
class EngineError {
  const EngineError(this.message, {this.canFallback = false});

  final String message;
  final bool canFallback;

  @override
  String toString() => message;
}

/// 打开一个媒体时的参数
class EngineMedia {
  const EngineMedia({required this.url, required this.headers, required this.userAgent, this.start = Duration.zero});

  final Uri url;

  /// 不含 User-Agent
  final Map<String, String> headers;
  final String userAgent;
  final Duration start;
}

/// 引擎选项（来自设置）
class EngineOptions {
  const EngineOptions({
    this.autoFrameRate = true,
    this.tunneling = false,
    this.bufferBytes = 256 * 1024 * 1024,
    this.cacheDir,
    this.hardwareDecoding = true,
  });

  /// mpv 硬解（关掉 = 软解；硬解花屏、绿屏的片源可以手动切）
  final bool hardwareDecoding;

  /// 预读缓冲上限（字节）
  final int bufferBytes;

  /// 磁盘缓存目录（mpv 缓冲超过内存上限时使用）
  final String? cacheDir;

  /// 按片源帧率切换显示刷新率（Android TV）
  final bool autoFrameRate;

  /// 隧道播放（部分电视盒子音画同步更好）
  final bool tunneling;
}

/// 画面比例
enum VideoFit {
  /// 完整显示，保持比例（有黑边）
  contain('适应'),

  /// 铺满屏幕，保持比例（裁掉多出的部分）
  cover('填满'),

  /// 铺满屏幕，不保持比例
  fill('拉伸');

  const VideoFit(this.label);
  final String label;
}

abstract class PlayerEngine {
  EngineKind get kind;

  ValueListenable<EngineState> get state;

  /// 播放结束
  Stream<void> get completed;
  Stream<EngineError> get errors;

  Future<void> open(EngineMedia media);
  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause() => state.value.playing ? pause() : play();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);

  /// 播放器音量 0–1（Windows 播放页调节；电视用系统音量，ExoPlayer 不需要实现）
  Future<void> setVolume(double volume) async {}

  /// 字幕延迟（正数 = 字幕推后）。ExoPlayer 不支持，只有 mpv 实现
  Future<void> setSubtitleDelay(Duration delay) async {}

  /// 字幕大小倍数（1 = 默认）
  Future<void> setSubtitleScale(double scale) async {}

  /// 字幕上下位置（mpv 的 sub-pos：100 = 默认的底部，数值越小越靠上）。只有 mpv 实现
  Future<void> setSubtitlePosition(int position) async {}

  /// 这个内核能不能调字幕位置
  bool get supportsSubtitlePosition => false;

  /// 画面比例：适应 / 填满（裁切）/ 拉伸
  Future<void> setVideoFit(VideoFit fit) async {}

  /// 往后预读最多多少（null = 不限制，按缓冲上限）。片尾会被跳过时不必下载片尾；不支持的内核忽略
  Future<void> setReadaheadLimit(Duration? limit) async {}

  /// 这个内核能不能调字幕延迟
  bool get supportsSubtitleDelay => false;

  /// 音画同步：声音相对画面的偏移（正数 = 声音推后）
  Future<void> setAudioDelay(Duration delay) async {}

  /// 这个内核能不能调音画同步
  bool get supportsAudioDelay => false;

  /// 字幕亮度（1 = 原样；HDR 片源上白色字幕刺眼时调暗）
  Future<void> setSubtitleBrightness(double brightness) async {}

  /// 能不能同时显示第二条字幕（双语字幕；mpv 的 secondary-sid，只支持文字字幕）
  bool get supportsSecondarySubtitle => false;

  /// 当前的第二字幕；null = 没开
  EngineTrack? get secondarySubtitle => null;

  /// 第二字幕显示在主字幕下方、字号小一点；null = 关闭。换片后自动关闭
  Future<void> selectSecondarySubtitle(EngineTrack? track) async {}

  /// 能不能在硬解和软解之间切换（mpv）
  bool get supportsDecoderSwitch => false;

  /// 切换硬解 / 软解
  Future<void> setHardwareDecoding(bool enabled) async {}
  Future<void> selectAudio(EngineTrack track);

  /// null = 关闭字幕
  Future<void> selectSubtitle(EngineTrack? track);
  Future<void> addExternalSubtitle(Uri url, {String? title, String? language});

  Widget buildView();
  Future<void> dispose();
}
