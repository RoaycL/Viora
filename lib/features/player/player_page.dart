import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../app/input/intents.dart';
import '../../app/theme.dart';
import '../../data/config/config_store.dart';
import '../../data/emby/emby_client.dart';
import '../../data/media/media_models.dart';
import '../../data/media/server_registry.dart';
import '../../ui/glass/glass.dart';
import '../../ui/panels/context_menu.dart';
import '../../ui/rows/cards.dart';
import '../../ui/widgets/buttons.dart';
import '../browse/media_cards.dart';

/// 播放页（docs/08-player.md、docs/07-input-control.md §3）。
///
/// M1：mpv（media_kit）内核，Windows 与 Android 通用；Android 的 ExoPlayer 内核在 M2 加入。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key, required this.serverId, required this.itemId, this.startMs = 0, this.sourceId});

  final String serverId;
  final String itemId;
  final int startMs;
  final String? sourceId;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  late final Player _player = Player(
    configuration: const PlayerConfiguration(title: 'Viora', bufferSize: 64 * 1024 * 1024),
  );
  late final VideoController _video = VideoController(_player);
  final _focus = FocusNode(debugLabel: 'player');
  final _subs = <StreamSubscription<Object?>>[];

  EmbyClient? _client;
  MediaItem? _item;
  MediaSourceInfo? _source;
  List<MediaSourceInfo> _sources = const [];
  String? _playSessionId;
  String? _error;
  String? _userAgent;

  bool _osd = true;
  Timer? _osdTimer;
  Timer? _progressTimer;
  bool _started = false;
  bool _stopped = false;

  /// 累加快进 / 快退（连续按键 0.8 秒后才真正 seek）
  Duration? _pendingSeek;
  Timer? _seekTimer;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _subs.addAll([
      _player.stream.playing.listen((playing) {
        if (!_started && playing) {
          _started = true;
          _report(start: true);
        } else if (_started) {
          _report(event: playing ? 'Unpause' : 'Pause');
        }
        _showOsd();
      }),
      _player.stream.completed.listen((done) {
        if (done) _onCompleted();
      }),
      _player.stream.error.listen((e) {
        if (!_started && mounted) setState(() => _error = e);
      }),
    ]);
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_started && _player.state.playing) _report();
    });
    _open();
  }

  Future<void> _open({String? sourceId, Duration? at}) async {
    try {
      final client = ref.read(serverClientProvider(widget.serverId));
      if (client == null) throw const MediaServerException('服务器不存在');
      _client = client;
      _item ??= await client.item(widget.itemId);
      final info = await client.playbackInfo(widget.itemId);
      if (info.sources.isEmpty) throw const MediaServerException('没有可播放的资源');
      final wanted = sourceId ?? widget.sourceId;
      final source = info.sources.where((s) => s.id == wanted).firstOrNull ?? info.sources.first;
      final req = client.stream(source, playSessionId: info.playSessionId);

      final native = _player.platform;
      if (native is NativePlayer) {
        // 自定义播放 UA（docs/03-media-servers.md §6），其余请求头由 httpHeaders 传入
        await native.setProperty('user-agent', req.userAgent);
        await native.setProperty('network-timeout', '20');
        await native.setProperty('demuxer-max-back-bytes', '${32 * 1024 * 1024}');
      }
      final headers = {...req.headers}..remove('User-Agent');
      final start = at ?? Duration(milliseconds: widget.startMs);
      await _player.open(Media(req.url.toString(), httpHeaders: headers, start: start > Duration.zero ? start : null));

      // 外挂字幕（服务器提供）在 mpv 内封轨道之外单独列出，见 _openTrackMenu
      if (!mounted) return;
      setState(() {
        _sources = info.sources;
        _source = source;
        _playSessionId = info.playSessionId ?? newPlaySessionId();
        _userAgent = req.userAgent;
        _error = null;
      });
      ref.read(configProvider.notifier).updateServer(widget.serverId, (s) => s.copyWith(lastAccessAt: DateTime.now()));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _report({bool start = false, String event = 'TimeUpdate'}) {
    final client = _client, source = _source;
    if (client == null || source == null || _stopped) return;
    final pos = _player.state.position;
    if (start) {
      client.reportStart(source, pos, _playSessionId);
    } else {
      client.reportProgress(source, pos, _playSessionId, paused: !_player.state.playing, event: event);
    }
  }

  void _reportStopped() {
    if (_stopped) return;
    _stopped = true;
    final client = _client, source = _source;
    if (client != null && source != null && _started) {
      client.reportStopped(source, _player.state.position, _playSessionId);
      ref.invalidate(resumeProvider);
      ref.invalidate(itemProvider((serverId: widget.serverId, itemId: widget.itemId)));
    }
  }

  Future<void> _onCompleted() async {
    _reportStopped();
    final item = _item, client = _client;
    if (item == null || client == null || !mounted) return;
    // 剧集自动播放下一集
    if (item.kind == MediaKind.episode && item.seriesId != null) {
      try {
        final eps = await client.episodes(item.seriesId!, seasonId: item.seasonId);
        final i = eps.indexWhere((e) => e.id == item.id);
        if (i >= 0 && i + 1 < eps.length && mounted) {
          context.pushReplacement('/play/${widget.serverId}/${eps[i + 1].id}?pos=0');
          return;
        }
      } catch (_) {}
    }
    if (mounted) context.pop();
  }

  @override
  void dispose() {
    _reportStopped();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    for (final s in _subs) {
      s.cancel();
    }
    _osdTimer?.cancel();
    _progressTimer?.cancel();
    _seekTimer?.cancel();
    _focus.dispose();
    _player.dispose();
    super.dispose();
  }

  // ───────────────────────── 操作 ─────────────────────────

  void _showOsd({bool sticky = false}) {
    _osdTimer?.cancel();
    if (!_osd && mounted) setState(() => _osd = true);
    if (!sticky) {
      _osdTimer = Timer(const Duration(seconds: 5), () {
        if (mounted && _player.state.playing) setState(() => _osd = false);
      });
    }
  }

  void _seekBy(Duration delta) {
    final duration = _player.state.duration;
    final base = _pendingSeek ?? _player.state.position;
    var target = base + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration - const Duration(seconds: 1);
    setState(() => _pendingSeek = target);
    _showOsd();
    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(milliseconds: 800), () {
      final t = _pendingSeek;
      if (t != null) _player.seek(t);
      if (mounted) setState(() => _pendingSeek = null);
      _report(event: 'TimeUpdate');
    });
  }

  void _exit() {
    if (_osd && _player.state.playing) {
      setState(() => _osd = false);
      return;
    }
    context.pop();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final step = Duration(seconds: ref.read(configProvider).playback.seekStepSeconds);
    final repeat = event is KeyRepeatEvent;

    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.keyJ) {
      _seekBy(-(repeat ? step * 3 : step));
    } else if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.keyL) {
      _seekBy(repeat ? step * 3 : step);
    } else if (repeat) {
      return KeyEventResult.handled;
    } else if (confirmKeys.contains(key) ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.keyK ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      _player.playOrPause();
      _showOsd();
    } else if (key == LogicalKeyboardKey.mediaPlay) {
      _player.play();
    } else if (key == LogicalKeyboardKey.mediaPause) {
      _player.pause();
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _showOsd();
    } else if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.gameButtonX) {
      _openTrackMenu();
    } else if (key == LogicalKeyboardKey.keyA) {
      _cycleAudio();
    } else if (key == LogicalKeyboardKey.keyC) {
      _cycleSubtitle();
    } else if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.gameButtonB ||
        key == LogicalKeyboardKey.backspace) {
      _exit();
    } else if (key == LogicalKeyboardKey.mediaStop) {
      context.pop();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  List<AudioTrack> get _audioTracks => _player.state.tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();

  List<SubtitleTrack> get _subtitleTracks =>
      _player.state.tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();

  void _cycleAudio() {
    final tracks = _audioTracks;
    if (tracks.isEmpty) return;
    final i = tracks.indexWhere((t) => t.id == _player.state.track.audio.id);
    _player.setAudioTrack(tracks[(i + 1) % tracks.length]);
    _showOsd();
  }

  void _cycleSubtitle() {
    final tracks = [SubtitleTrack.no(), ..._subtitleTracks];
    final i = tracks.indexWhere((t) => t.id == _player.state.track.subtitle.id);
    _player.setSubtitleTrack(tracks[(i + 1) % tracks.length]);
    _showOsd();
  }

  String _trackName(String id, String? title, String? language, String? codec) {
    final parts = [?title, ?language, if (codec != null) codec.toUpperCase()];
    return parts.isEmpty ? '轨道 $id' : parts.join(' · ');
  }

  Future<void> _openTrackMenu() async {
    _showOsd(sticky: true);
    await showContextMenu(
      context,
      title: '播放设置',
      actions: [
        MenuAction('音轨 · ${_audioTracks.length} 条', Icons.audiotrack_rounded, () {
          final current = _player.state.track.audio.id;
          showContextMenu(
            context,
            title: '音轨',
            actions: [
              for (final t in _audioTracks)
                MenuAction(
                  '${_trackName(t.id, t.title, t.language, t.codec)}${t.id == current ? '  ✓' : ''}',
                  Icons.graphic_eq_rounded,
                  () => _player.setAudioTrack(t),
                ),
            ],
          );
        }),
        MenuAction('字幕 · ${_subtitleTracks.length} 条', Icons.subtitles_rounded, () {
          final current = _player.state.track.subtitle.id;
          final external = _source?.subtitles.where((s) => s.isExternal).toList() ?? const <MediaStreamInfo>[];
          showContextMenu(
            context,
            title: '字幕',
            actions: [
              MenuAction('关闭字幕${current == 'no' ? '  ✓' : ''}', Icons.subtitles_off_rounded, () {
                _player.setSubtitleTrack(SubtitleTrack.no());
              }),
              for (final t in _subtitleTracks)
                MenuAction(
                  '${_trackName(t.id, t.title, t.language, t.codec)}${t.id == current ? '  ✓' : ''}',
                  Icons.closed_caption_rounded,
                  () => _player.setSubtitleTrack(t),
                ),
              for (final s in external)
                MenuAction('外挂 · ${s.displayName}', Icons.closed_caption_outlined, () {
                  final req = _client?.subtitle(_source!, s);
                  if (req != null) {
                    _player.setSubtitleTrack(
                      SubtitleTrack.uri(req.url.toString(), title: s.displayName, language: s.language),
                    );
                  }
                }),
            ],
          );
        }),
        if (_sources.length > 1)
          MenuAction('切换资源 · ${_sources.length} 个版本', Icons.swap_horiz_rounded, () {
            showContextMenu(
              context,
              title: '切换资源',
              actions: [
                for (final s in _sources)
                  MenuAction(
                    '${s.resolutionLabel} ${s.rangeLabel}'
                    '${s.size == null ? '' : ' · ${(s.size! / 1073741824).toStringAsFixed(2)} GB'}'
                    '${s.id == _source?.id ? '  ✓' : ''}',
                    Icons.movie_rounded,
                    () {
                      final at = _player.state.position;
                      _reportStopped();
                      _stopped = false;
                      _started = false;
                      _open(sourceId: s.id, at: at);
                    },
                  ),
              ],
            );
          }),
        MenuAction('倍速 · ${_player.state.rate}x', Icons.speed_rounded, () {
          showContextMenu(
            context,
            title: '倍速',
            actions: [
              for (final r in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                MenuAction(
                  '${r}x${_player.state.rate == r ? '  ✓' : ''}',
                  Icons.speed_rounded,
                  () => _player.setRate(r),
                ),
            ],
          );
        }),
      ],
    );
    if (mounted) _focus.requestFocus();
    _showOsd();
  }

  // ───────────────────────── 界面 ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final title = item == null
        ? ''
        : item.kind == MediaKind.episode
        ? (item.seriesName ?? item.name)
        : item.name;
    final subtitle = item?.kind == MediaKind.episode ? '${item!.episodeLabel ?? ''} · ${item.name}' : null;

    return Material(
      color: Colors.black,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          onHover: (_) => _showOsd(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _player.playOrPause();
              _showOsd();
            },
            onDoubleTap: _openTrackMenu,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Video(controller: _video, controls: NoVideoControls, fill: Colors.black),
                if (_error != null)
                  _ErrorPanel(
                    message: _error!,
                    userAgent: _userAgent,
                    onRetry: () {
                      setState(() => _error = null);
                      _open(sourceId: _source?.id);
                    },
                  ),
                // 缓冲指示
                StreamBuilder<bool>(
                  stream: _player.stream.buffering,
                  builder: (context, snap) => snap.data == true && _error == null
                      ? const Center(
                          child: SizedBox(
                            width: 72,
                            height: 72,
                            child: CircularProgressIndicator(strokeWidth: 5, color: Colors.white),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                if (_pendingSeek != null)
                  Center(
                    child: Glass(
                      radius: 24,
                      padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 20),
                      child: Text(formatClock(_pendingSeek!), style: VText.h2.copyWith(fontSize: 44)),
                    ),
                  ),
                IgnorePointer(
                  ignoring: !_osd,
                  child: AnimatedOpacity(
                    opacity: _osd ? 1 : 0,
                    duration: VMotion.scroll,
                    child: _Osd(
                      player: _player,
                      title: title,
                      subtitle: subtitle,
                      source: _source,
                      pendingSeek: _pendingSeek,
                      onMenu: _openTrackMenu,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Osd extends StatelessWidget {
  const _Osd({
    required this.player,
    required this.title,
    required this.subtitle,
    required this.source,
    required this.pendingSeek,
    required this.onMenu,
  });

  final Player player;
  final String title;
  final String? subtitle;
  final MediaSourceInfo? source;
  final Duration? pendingSeek;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0, 0.22, 0.6, 1],
              colors: [Color(0xBF000000), Color(0x00000000), Color(0x00000000), Color(0xD9000000)],
            ),
          ),
        ),
        Positioned(
          left: VSpace.safeH,
          right: VSpace.safeH,
          top: VSpace.safeV,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w700)),
                    if (subtitle != null) Text(subtitle!, style: VText.label.copyWith(color: VColors.textSecondary)),
                  ],
                ),
              ),
              if (source != null)
                Glass(
                  radius: 999,
                  blur: 24,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  child: Text(
                    '${source!.resolutionLabel} ${source!.rangeLabel} · ${source!.container.split(',').first.toUpperCase()}',
                    style: VText.small.copyWith(color: VColors.rating),
                  ),
                ),
            ],
          ),
        ),
        Positioned(
          left: VSpace.safeH,
          right: VSpace.safeH,
          bottom: VSpace.safeV,
          child: Glass(
            radius: 32,
            blur: 36,
            fill: const Color(0x6B14161E),
            padding: const EdgeInsets.fromLTRB(36, 28, 36, 26),
            child: StreamBuilder<Duration>(
              stream: player.stream.position,
              builder: (context, _) {
                final pos = pendingSeek ?? player.state.position;
                final dur = player.state.duration;
                final playing = player.state.playing;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        SizedBox(width: 110, child: Text(formatClock(pos), style: VText.label)),
                        Expanded(
                          child: ProgressLine(
                            dur.inMilliseconds == 0 ? 0 : pos.inMilliseconds / dur.inMilliseconds,
                            height: 10,
                          ),
                        ),
                        SizedBox(
                          width: 110,
                          child: Text(
                            formatClock(dur),
                            textAlign: TextAlign.right,
                            style: VText.label.copyWith(color: VColors.textSecondary),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 40),
                        const SizedBox(width: 20),
                        Text(
                          'OK 暂停/播放 · ←→ 快退/快进 · ↓ 或菜单键 音轨/字幕/资源 · 返回 退出',
                          style: VText.small.copyWith(color: VColors.textTertiary),
                        ),
                        const Spacer(),
                        PillButton(label: '音轨 / 字幕', icon: Icons.tune_rounded, onPressed: onMenu),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.userAgent, required this.onRetry});

  final String message;
  final String? userAgent;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final forbidden = message.contains('403') || message.contains('401');
    return Center(
      child: Glass(
        width: 900,
        radius: 32,
        padding: const EdgeInsets.all(44),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('无法播放', style: VText.h2),
            const SizedBox(height: 16),
            Text(message, style: VText.label.copyWith(color: VColors.bad)),
            const SizedBox(height: 16),
            Text(
              forbidden ? '服务器拒绝了播放请求：检查「设置 → 播放」里的播放 UA / 客户端名称，或重新登录。' : '可能是线路不通或格式不受支持：在资源库里对这台服务器测速 / 切换线路后重试。',
              style: VText.caption.copyWith(color: VColors.textSecondary),
            ),
            if (userAgent != null) ...[
              const SizedBox(height: 10),
              Text('当前播放 UA：$userAgent', style: VText.small.copyWith(color: VColors.textMuted)),
            ],
            const SizedBox(height: 28),
            Row(
              children: [
                PillButton(autofocus: true, icon: Icons.refresh_rounded, label: '重试', onPressed: onRetry),
                const SizedBox(width: 24),
                PillButton(label: '返回', onPressed: () => context.pop()),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
