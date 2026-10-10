import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/input/intents.dart';
import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../../data/aggregate/sources.dart';
import '../../data/config/app_config.dart';
import '../../data/config/config_store.dart';
import '../../data/emby/emby_client.dart';
import '../../data/media/media_models.dart';
import '../../data/media/server_registry.dart';
import '../../player/engine.dart';
import '../../player/exo_engine.dart';
import '../../player/mpv_engine.dart';
import '../../ui/glass/glass.dart';
import '../../ui/panels/context_menu.dart';
import '../../ui/rows/cards.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/toast.dart';
import '../browse/media_cards.dart';

/// 播放页（docs/08-player.md、docs/07-input-control.md §3）。
///
/// 内核：Windows 用 mpv；Android 默认 ExoPlayer（HDR / 音频直通、自动帧率），
/// ExoPlayer 解码或格式不支持时自动换 mpv 重试。
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
  final _focus = FocusNode(debugLabel: 'player');
  final _engineSubs = <StreamSubscription<Object?>>[];

  PlayerEngine? _engine;
  EmbyClient? _client;
  MediaItem? _item;
  MediaSourceInfo? _source;
  String? _playSessionId;
  PlaybackRequest? _request;
  String? _error;

  /// 本次播放已经从 ExoPlayer 回退过 mpv
  bool _fellBack = false;

  bool _osd = true;
  bool _info = false;
  Timer? _osdTimer;
  Timer? _progressTimer;
  bool _started = false;
  bool _stopped = false;
  bool _wasPlaying = false;

  /// 累加快进 / 快退（连续按键 0.8 秒后才真正 seek）
  Duration? _pendingSeek;
  Timer? _seekTimer;

  EngineState get _state => _engine?.state.value ?? const EngineState();

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_started && _state.playing) _report();
    });
    _start();
  }

  // ───────────────────────── 内核 ─────────────────────────

  EngineOptions get _options {
    final p = ref.read(configProvider).playback;
    return EngineOptions(autoFrameRate: p.autoFrameRate, tunneling: p.tunneling);
  }

  PlayerEngine _createEngine({bool forceMpv = false, bool forceExo = false}) {
    final p = ref.read(configProvider).playback;
    final useExo = ExoEngine.supported && (forceExo || (!forceMpv && p.engine != EnginePreference.mpv));
    return useExo ? ExoEngine(options: _options) : MpvEngine();
  }

  Future<void> _attachEngine(PlayerEngine engine) async {
    for (final s in _engineSubs) {
      await s.cancel();
    }
    _engineSubs.clear();
    final old = _engine;
    if (old != null) {
      old.state.removeListener(_onEngineState);
      setState(() => _engine = null);
      await old.dispose();
    }
    _engine = engine;
    engine.state.addListener(_onEngineState);
    _engineSubs.addAll([engine.completed.listen((_) => _onCompleted()), engine.errors.listen(_onEngineError)]);
    if (mounted) setState(() {});
  }

  void _onEngineState() {
    final s = _state;
    if (s.playing != _wasPlaying) {
      _wasPlaying = s.playing;
      if (!_started && s.playing) {
        _started = true;
        _report(start: true);
      } else if (_started) {
        _report(event: s.playing ? 'Unpause' : 'Pause');
      }
      _showOsd();
    }
  }

  Future<void> _onEngineError(EngineError e) async {
    final engine = _engine;
    final auto = ref.read(configProvider).playback.engine == EnginePreference.auto;
    if (engine is ExoEngine && e.canFallback && auto && !_fellBack) {
      _fellBack = true;
      showToast('ExoPlayer 无法播放（${e.message}），已切换到 mpv');
      await _switchEngine(forceMpv: true);
      return;
    }
    if (!_started && mounted) setState(() => _error = e.message);
  }

  Future<void> _switchEngine({bool forceMpv = false, bool forceExo = false}) async {
    final at = _state.position > Duration.zero ? _state.position : Duration(milliseconds: widget.startMs);
    await _attachEngine(_createEngine(forceMpv: forceMpv, forceExo: forceExo));
    await _openCurrent(at);
  }

  Future<void> _openCurrent(Duration at) async {
    final req = _request;
    final engine = _engine;
    if (req == null || engine == null) return;
    final headers = {...req.headers}..remove('User-Agent');
    await engine.open(EngineMedia(url: req.url, headers: headers, userAgent: req.userAgent, start: at));
  }

  // ───────────────────────── 打开媒体 ─────────────────────────

  Future<void> _start({String? sourceId, Duration? at}) async {
    try {
      final client = ref.read(serverClientProvider(widget.serverId));
      if (client == null) throw const MediaServerException('服务器不存在');
      _client = client;
      _item ??= await client.item(widget.itemId);
      final info = await client.playbackInfo(widget.itemId);
      if (info.sources.isEmpty) throw const MediaServerException('没有可播放的资源');
      final wanted = sourceId ?? widget.sourceId;
      final source = info.sources.where((s) => s.id == wanted).firstOrNull ?? info.sources.first;
      _request = client.stream(source, playSessionId: info.playSessionId);
      if (!mounted) return;
      setState(() {
        _source = source;
        _playSessionId = info.playSessionId ?? newPlaySessionId();
        _error = null;
      });
      if (_engine == null) await _attachEngine(_createEngine());
      await _openCurrent(at ?? Duration(milliseconds: widget.startMs));
      ref.read(configProvider.notifier).updateServer(widget.serverId, (s) => s.copyWith(lastAccessAt: DateTime.now()));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  // ───────────────────────── 进度上报 ─────────────────────────

  void _report({bool start = false, String event = 'TimeUpdate'}) {
    final client = _client, source = _source;
    if (client == null || source == null || _stopped) return;
    final pos = _state.position;
    if (start) {
      client.reportStart(source, pos, _playSessionId);
    } else {
      client.reportProgress(source, pos, _playSessionId, paused: !_state.playing, event: event);
    }
  }

  void _reportStopped() {
    if (_stopped) return;
    _stopped = true;
    final client = _client, source = _source;
    if (client != null && source != null && _started) {
      client.reportStopped(source, _state.position, _playSessionId);
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
    for (final s in _engineSubs) {
      s.cancel();
    }
    _osdTimer?.cancel();
    _progressTimer?.cancel();
    _seekTimer?.cancel();
    _focus.dispose();
    _engine?.state.removeListener(_onEngineState);
    _engine?.dispose();
    super.dispose();
  }

  // ───────────────────────── 操作 ─────────────────────────

  void _showOsd({bool sticky = false}) {
    _osdTimer?.cancel();
    if (!_osd && mounted) setState(() => _osd = true);
    if (!sticky) {
      _osdTimer = Timer(const Duration(seconds: 5), () {
        if (mounted && _state.playing) setState(() => _osd = false);
      });
    }
  }

  void _seekBy(Duration delta) {
    final duration = _state.duration;
    final base = _pendingSeek ?? _state.position;
    var target = base + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration - const Duration(seconds: 1);
    setState(() => _pendingSeek = target);
    _showOsd();
    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(milliseconds: 800), () {
      final t = _pendingSeek;
      if (t != null) _engine?.seek(t);
      if (mounted) setState(() => _pendingSeek = null);
      _report();
    });
  }

  void _togglePlay() {
    _engine?.playOrPause();
    _showOsd();
  }

  void _exit() {
    if (_info) {
      setState(() => _info = false);
      return;
    }
    if (_osd && _state.playing) {
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
      _togglePlay();
    } else if (key == LogicalKeyboardKey.mediaPlay) {
      _engine?.play();
    } else if (key == LogicalKeyboardKey.mediaPause) {
      _engine?.pause();
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _showOsd();
    } else if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.gameButtonX) {
      _openMenu();
    } else if (key == LogicalKeyboardKey.keyI || key == LogicalKeyboardKey.info) {
      setState(() => _info = !_info);
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

  void _cycleAudio() {
    final tracks = _state.audioTracks;
    if (tracks.isEmpty) return;
    final i = tracks.indexOf(_state.audio ?? tracks.first);
    final next = tracks[(i + 1) % tracks.length];
    _engine?.selectAudio(next);
    showToast('音轨：${next.displayName}');
  }

  void _cycleSubtitle() {
    final tracks = <EngineTrack?>[null, ..._state.subtitleTracks];
    final i = tracks.indexOf(_state.subtitle);
    final next = tracks[(i + 1) % tracks.length];
    _engine?.selectSubtitle(next);
    showToast('字幕：${next?.displayName ?? '关闭'}');
  }

  Future<void> _openMenu() async {
    _showOsd(sticky: true);
    final s = _state;
    final engine = _engine;
    await showContextMenu(
      context,
      title: '播放设置',
      actions: [
        MenuAction('音轨 · ${s.audioTracks.length} 条', Icons.audiotrack_rounded, () {
          showContextMenu(
            context,
            title: '音轨',
            actions: [
              for (final t in s.audioTracks)
                MenuAction(
                  '${t.displayName}${t == s.audio ? '  ✓' : ''}',
                  Icons.graphic_eq_rounded,
                  () => _engine?.selectAudio(t),
                ),
            ],
          );
        }),
        MenuAction('字幕 · ${s.subtitleTracks.length} 条', Icons.subtitles_rounded, () {
          final external = _source?.subtitles.where((x) => x.isExternal).toList() ?? const <MediaStreamInfo>[];
          showContextMenu(
            context,
            title: '字幕',
            actions: [
              MenuAction(
                '关闭字幕${s.subtitle == null ? '  ✓' : ''}',
                Icons.subtitles_off_rounded,
                () => _engine?.selectSubtitle(null),
              ),
              for (final t in s.subtitleTracks)
                MenuAction(
                  '${t.displayName}${t == s.subtitle ? '  ✓' : ''}',
                  Icons.closed_caption_rounded,
                  () => _engine?.selectSubtitle(t),
                ),
              for (final x in external)
                MenuAction('外挂 · ${x.displayName}', Icons.closed_caption_outlined, () {
                  final req = _client?.subtitle(_source!, x);
                  if (req != null) _engine?.addExternalSubtitle(req.url, title: x.displayName, language: x.language);
                }),
            ],
          );
        }),
        MenuAction('切换资源（所有服务器）', Icons.swap_horiz_rounded, _openSourcesMenu),
        MenuAction('倍速 · ${s.rate}x', Icons.speed_rounded, () {
          showContextMenu(
            context,
            title: '倍速',
            actions: [
              for (final r in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                MenuAction('${r}x${s.rate == r ? '  ✓' : ''}', Icons.speed_rounded, () => _engine?.setRate(r)),
            ],
          );
        }),
        if (ExoEngine.supported && engine != null)
          MenuAction(
            '播放内核 · ${engine.kind.label}（切换到 ${engine.kind == EngineKind.exo ? 'mpv' : 'ExoPlayer'}）',
            Icons.memory_rounded,
            () => _switchEngine(forceMpv: engine.kind == EngineKind.exo, forceExo: engine.kind == EngineKind.mpv),
          ),
        MenuAction('媒体信息', Icons.info_outline_rounded, () => setState(() => _info = true)),
      ],
    );
    if (mounted) _focus.requestFocus();
    _showOsd();
  }

  /// 所有服务器上的版本；选其他服务器的版本时换到那台服务器从当前进度继续
  Future<void> _openSourcesMenu() async {
    showToast('正在查找各服务器上的资源…');
    List<SourceOption> options;
    try {
      options = await ref.read(sourceOptionsProvider((serverId: widget.serverId, itemId: widget.itemId)).future);
    } catch (e) {
      showToast('查找资源失败：$e');
      return;
    }
    if (!mounted) return;
    if (options.isEmpty) {
      showToast('没有其他可用资源');
      return;
    }
    await showContextMenu(
      context,
      title: '切换资源 · ${options.length} 个版本',
      actions: [
        for (final o in options)
          MenuAction(
            '${o.source.resolutionLabel} ${o.source.rangeLabel}'
            '${o.source.size == null ? '' : ' · ${(o.source.size! / 1073741824).toStringAsFixed(2)} GB'}'
            ' · ${o.serverName}'
            '${o.serverId == widget.serverId && o.source.id == _source?.id ? '  ✓' : ''}',
            Icons.movie_rounded,
            () {
              final at = _state.position;
              if (o.serverId == widget.serverId && o.item.id == widget.itemId) {
                _reportStopped();
                _stopped = false;
                _started = false;
                _wasPlaying = false;
                _start(sourceId: o.source.id, at: at);
              } else {
                context.pushReplacement(o.playRoute(position: at));
              }
            },
          ),
      ],
    );
    if (mounted) _focus.requestFocus();
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
    final engine = _engine;

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
            onTap: _togglePlay,
            onDoubleTap: _openMenu,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (engine != null) KeyedSubtree(key: ObjectKey(engine), child: engine.buildView()),
                if (_error != null)
                  _ErrorPanel(
                    message: _error!,
                    userAgent: _request?.userAgent,
                    onRetry: () {
                      setState(() => _error = null);
                      _start(sourceId: _source?.id);
                    },
                    onSwitchEngine: ExoEngine.supported && engine != null
                        ? () {
                            setState(() => _error = null);
                            _switchEngine(
                              forceMpv: engine.kind == EngineKind.exo,
                              forceExo: engine.kind == EngineKind.mpv,
                            );
                          }
                        : null,
                  ),
                if (engine != null)
                  ValueListenableBuilder<EngineState>(
                    valueListenable: engine.state,
                    builder: (context, s, _) => Stack(
                      fit: StackFit.expand,
                      children: [
                        if (s.buffering && _error == null)
                          const Center(
                            child: SizedBox(
                              width: 72,
                              height: 72,
                              child: CircularProgressIndicator(strokeWidth: 5, color: Colors.white),
                            ),
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
                              state: s,
                              title: title,
                              subtitle: subtitle,
                              source: _source,
                              pendingSeek: _pendingSeek,
                              onMenu: _openMenu,
                              onBack: () => context.pop(),
                            ),
                          ),
                        ),
                        if (_info)
                          Positioned(
                            right: VSpace.safeH,
                            top: 150,
                            child: _InfoPanel(state: s, engine: engine.kind, source: _source, request: _request),
                          ),
                      ],
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
    required this.state,
    required this.title,
    required this.subtitle,
    required this.source,
    required this.pendingSeek,
    required this.onMenu,
    required this.onBack,
  });

  final VoidCallback onBack;
  final EngineState state;
  final String title;
  final String? subtitle;
  final MediaSourceInfo? source;
  final Duration? pendingSeek;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final pos = pendingSeek ?? state.position;
    final dur = state.duration;
    final hdr = state.video.hdr ?? source?.rangeLabel;
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
              // Windows 用鼠标时需要可点击的返回按钮；TV 用遥控器返回键
              if (PlatformProfile.isDesktop) ...[
                CircleIconButton(icon: Icons.arrow_back_rounded, tooltip: '返回', onPressed: onBack),
                const SizedBox(width: 24),
              ],
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
                    '${source!.resolutionLabel} ${hdr ?? ''} · ${source!.container.split(',').first.toUpperCase()}',
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
            child: Column(
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
                    Icon(state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 40),
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
            ),
          ),
        ),
      ],
    );
  }
}

/// 媒体信息叠加层（I 键 / 菜单 → 媒体信息）
class _InfoPanel extends StatelessWidget {
  const _InfoPanel({required this.state, required this.engine, required this.source, required this.request});

  final EngineState state;
  final EngineKind engine;
  final MediaSourceInfo? source;
  final PlaybackRequest? request;

  @override
  Widget build(BuildContext context) {
    final v = state.video;
    final rows = <(String, String)>[
      ('播放内核', engine.label),
      if (v.decoder != null) ('解码器', v.decoder!),
      if (v.width != null) ('分辨率', '${v.width} × ${v.height}'),
      if (v.frameRate != null) ('帧率', '${v.frameRate!.toStringAsFixed(3)} fps'),
      ('动态范围', v.hdr ?? source?.rangeLabel ?? 'SDR'),
      if (v.codec != null) ('视频编码', v.codec!),
      if (state.audio != null) ('音轨', state.audio!.displayName),
      if (source?.bitrate != null) ('码率', '${(source!.bitrate! / 1000000).toStringAsFixed(2)} Mbps'),
      ('缓冲', '${(state.buffered - state.position).inSeconds} 秒'),
      if (request != null) ('播放 UA', request!.userAgent),
    ];
    return Glass(
      width: 620,
      radius: 24,
      fill: const Color(0x9914161E),
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('媒体信息', style: VText.rowTitle),
          const SizedBox(height: 16),
          for (final (k, val) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 130,
                    child: Text(k, style: VText.small.copyWith(color: VColors.textTertiary)),
                  ),
                  Expanded(child: Text(val, style: VText.small)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.userAgent, required this.onRetry, this.onSwitchEngine});

  final String message;
  final String? userAgent;
  final VoidCallback onRetry;
  final VoidCallback? onSwitchEngine;

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
              forbidden
                  ? '服务器拒绝了播放请求：检查「设置 → 播放」里的播放 UA / 客户端名称，或重新登录。'
                  : '可能是线路不通或格式不受支持：可以换一个播放内核，或在资源库里对这台服务器测速 / 切换线路后重试。',
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
                if (onSwitchEngine != null) ...[
                  const SizedBox(width: 24),
                  PillButton(icon: Icons.memory_rounded, label: '换个内核', onPressed: onSwitchEngine),
                ],
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
