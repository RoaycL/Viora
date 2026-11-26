import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/desktop_prefs.dart';
import '../../app/desktop_tray.dart';
import '../../app/input/back_handler.dart';
import '../../app/input/intents.dart';
import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../../app/window_frame.dart';
import '../../core/log/app_log.dart';
import '../../data/aggregate/sources.dart';
import '../../data/cache/account_scope.dart';
import '../../data/config/app_config.dart';
import '../../data/config/config_store.dart';
import '../../data/danmaku/danmaku_client.dart';
import '../../data/danmaku/danmaku_models.dart';
import '../../data/emby/emby_client.dart';
import '../../data/subtitles/online_subtitles.dart';
import '../../data/history/pending_reports.dart';
import '../../data/history/play_history.dart';
import '../../data/index/index_sync.dart';
import '../../data/index/media_index.dart';
import '../../data/media/media_models.dart';
import '../../data/media/server_registry.dart';
import '../../domain/models/segment.dart';
import '../../domain/models/segment_settings.dart';
import '../../player/chapters.dart';
import '../../data/download/downloads.dart';
import '../../player/engine.dart';
import '../../player/sleep_timer.dart';
import '../../player/exo_engine.dart';
import '../../player/manual_segments.dart';
import '../../player/mpv_engine.dart';
import '../../player/playback_cache.dart';
import '../../player/preload.dart';
import '../../player/segment_playback_session.dart';
import '../../player/segment_skip_controller.dart';
import '../../player/subtitle_pick.dart';
import '../../player/trickplay.dart';
import '../../ui/focus/input_mode.dart';
import '../../ui/glass/glass.dart';
import '../../ui/panels/context_menu.dart';
import '../../ui/panels/form_dialog.dart';
import '../../ui/scale/design_scale.dart';
import '../../ui/widgets/buttons.dart';
import '../../ui/widgets/form.dart';
import '../../ui/widgets/toast.dart';
import '../browse/media_cards.dart';
import '../danmaku/danmaku_layer.dart';
import '../danmaku/danmaku_service.dart';
import '../segments/segment_service.dart';
import 'mini_player.dart';
import 'player_osd.dart';
import 'slider_adjuster.dart';

/// 连续自动播放（片尾倒计时结束、播完自动下一集，中间没有任何按键 / 点击）了几集：到 3 集时问「还在观看吗？」
int _autoPlayStreak = 0;

/// 下一个播放页是不是自动播放过来的（自动连播时设置，新播放页读取后清掉）
bool _arrivingByAutoPlay = false;

/// 整部剧的集列表缓存（按服务器 + 剧，3 分钟）：连播时每一集都是新的播放页，不用每次打开「选集」都重新取
final _episodeCache = <String, (DateTime, Future<List<MediaItem>>)>{};

/// 剧集所属的剧（片头片尾按剧的 TMDB / IMDb ID 查、手动标记按剧保存），按服务器 + 剧缓存 10 分钟：
/// 连播的下一集起播前就能拿到，不用再等一次请求
final _seriesCache = <String, (DateTime, Future<MediaItem>)>{};

Future<MediaItem> _seriesItem(EmbyClient client, String seriesId) {
  final key = '${accountScope(client.server)}/$seriesId';
  final hit = _seriesCache[key];
  if (hit != null && DateTime.now().difference(hit.$1) < const Duration(minutes: 10)) return hit.$2;
  final future = client.item(seriesId);
  _seriesCache
    ..remove(key)
    ..[key] = (DateTime.now(), future);
  while (_seriesCache.length > 8) {
    _seriesCache.remove(_seriesCache.keys.first);
  }
  future.then(
    (_) {},
    onError: (_) {
      _seriesCache.remove(key);
    },
  );
  return future;
}

/// 播放页（docs/08-player.md、docs/07-input-control.md §3）。
///
/// 内核：Windows 用 mpv；Android 默认 ExoPlayer（HDR / 音频直通、自动帧率），
/// ExoPlayer 解码或格式不支持时自动换 mpv 重试。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({
    super.key,
    required this.serverId,
    required this.itemId,
    this.startMs = 0,
    this.sourceId,
    this.triedSources = const [],
    this.resume = false,
    this.progressAt,
  });

  final String serverId;
  final String itemId;
  final int startMs;

  /// 继续播放：起播前向服务器取这一集最新的进度，从那里开始（[startMs] 只在取不到时用）。
  /// 卡片 / 详情页上的进度可能是缓存的旧数据，别的设备看到了更后面时，从旧位置播放、上报会把服务器进度覆盖回去。
  /// 「从头播放」、切换资源时接着当前位置等明确指定了位置的不设
  final bool resume;

  /// 和 [resume] 一起用：[startMs] 是另一台服务器上的进度，这是那次播放的时间（毫秒时间戳）。
  /// 这台服务器上的进度比它新时用这台的，否则用 [startMs]（这台的 0 / 旧进度不能把它覆盖掉）
  final int? progressAt;
  final String? sourceId;

  /// 自动换源时已经试过、打不开的版本（「服务器/版本 ID」），换到其他服务器时带过去，避免来回切
  final List<String> triedSources;

  /// 测试用：换成假的播放内核（测试环境里 mpv / ExoPlayer 都跑不起来），用来测遥控器操作、面板、返回键
  @visibleForTesting
  static PlayerEngine Function(EngineOptions options)? debugEngineFactory;

  /// 测试用：按住方向键加速用的时钟
  @visibleForTesting
  static DateTime Function() debugNow = DateTime.now;

  @visibleForTesting
  static void debugClearEpisodeCache() => _episodeCache.clear();

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> with WidgetsBindingObserver {
  /// 电视：应用退到后台（按主页键、切换信号源、进屏保）时暂停。不暂停的话画面看不见了声音还在放，
  /// 进度也在继续走。回到应用后保持暂停，由用户按 OK 继续。Windows 最小化后照常播放（后台听声音）
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!PlatformProfile.isTv) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      if (_state.playing) _engine?.pause();
    }
  }

  /// 画面本身（不在按钮上时接收快进 / 暂停等按键）。不参与方向导航：它铺满整个屏幕，
  /// 按位置找下一个控件时会被当成「最近的」，焦点从按钮跳到它上面就看不见了（电视上「丢失指针」）
  final _focus = FocusNode(debugLabel: 'player', skipTraversal: true);
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

  /// 自动换源：开播前打不开时按排序换下一个版本（已试过的不再试）
  late final _tried = {...widget.triedSources};
  bool _failingOver = false;

  bool _osd = true;

  /// Windows：「跳过片头」按钮出现 3 秒后收起（控制层显示时再出现），不一直挡着画面
  bool _skipFaded = false;
  Timer? _skipFadeTimer;
  static const skipButtonSeconds = 3;

  bool get _skipVisible => _skipPrompt != null && (PlatformProfile.isTv || !_skipFaded || _osd);
  bool _info = false;
  Timer? _osdTimer;
  Timer? _progressTimer;
  bool _started = false;
  bool _stopped = false;
  bool _wasPlaying = false;

  /// 片头片尾（docs/05 §3）：起播后后台解析，不阻塞播放
  SegmentPlaybackSession? _segments;
  SegmentSkipAction? _skipPrompt;
  List<Segment> _segmentList = const [];

  /// 弹幕（docs/10-danmaku.md）：起播后后台匹配加载，不阻塞播放
  DanmakuTrack? _danmaku;
  DanmakuTarget? _danmakuTarget;
  DanmakuChoice _danmakuChoice = const DanmakuChoice();
  bool _danmakuVisible = true;
  bool _danmakuLoading = false;
  String? _danmakuError;

  /// 剧集看到 85% 时预加载的下一集（播完直接跳过去，起播更快）
  MediaItem? _nextEpisode;

  /// 下一集（跨季）：片尾跳过、预加载、播放结束、「下一集」按钮共用，只查询一次
  Future<MediaItem?>? _nextEpisodeFuture;

  Future<MediaItem?> _resolveNextEpisode() {
    final item = _item, client = _client;
    if (item == null || client == null || item.kind != MediaKind.episode || item.seriesId == null) {
      return Future.value();
    }
    // 和「选集」面板共用一次请求：开播时就拿到整部剧的集列表，之后打开选集直接显示
    final episodes = _episodeList(client, item.seriesId!);
    return _nextEpisodeFuture ??= episodes.then((all) => _nextEpisode ??= nextEpisodeAfter(all, item)).catchError((
      Object _,
    ) {
      _nextEpisodeFuture = null; // 失败了下次再查
      return null;
    });
  }

  bool _nextPreloading = false;

  /// 控制层底部的面板（播放资源 / 选集）
  OsdPanel _panel = OsdPanel.none;
  Future<List<MediaItem>>? _episodes;
  bool _episodesFailed = false;

  /// 整部剧的集列表（选集面板和「下一集」共用）；上次请求失败了就重新请求
  Future<List<MediaItem>> _episodeList(EmbyClient client, String seriesId) {
    if (_episodesFailed) {
      _episodes = null;
      _episodesFailed = false;
    }
    return _episodes ??= _loadEpisodes(client, seriesId);
  }

  Future<List<MediaItem>> _loadEpisodes(EmbyClient client, String seriesId) {
    final key = '${accountScope(client.server)}/$seriesId';
    final hit = _episodeCache[key];
    if (hit != null && DateTime.now().difference(hit.$1) < const Duration(minutes: 3)) return hit.$2;
    final future = client.episodes(seriesId);
    _episodeCache
      ..remove(key)
      ..[key] = (DateTime.now(), future);
    while (_episodeCache.length > 4) {
      _episodeCache.remove(_episodeCache.keys.first);
    }
    // 失败的不留着；下次打开选集或查下一集时重新请求
    future.then(
      (_) {},
      onError: (_) {
        if (identical(_episodes, future)) _episodesFailed = true;
        if (identical(_episodeCache[key]?.$2, future)) _episodeCache.remove(key);
      },
    );
    return future;
  }

  /// 这一集在当前服务器上的所有版本（起播时已经拿到）：「播放资源」面板先显示它们
  List<MediaSourceInfo> _knownSources = const [];

  List<SourceOption> get _knownOptions {
    final item = _item, client = _client;
    if (item == null || client == null) return const [];
    final config = ref.read(configProvider);
    return [
      for (final s in _knownSources)
        SourceOption(
          item: item,
          source: s,
          serverName: client.server.displayName,
          latencyMs: client.server.lines.isEmpty ? null : client.line.latencyMs,
          account: accountScope(client.server),
          view: mediaViewScope(config),
        ),
    ];
  }

  /// 鼠标停在控制栏上（Windows）
  bool _hoverControls = false;
  final _playNode = FocusNode(debugLabel: 'osd-play');
  final _topNode = FocusNode(debugLabel: 'osd-top');

  /// 累加快进 / 快退（连续按键 0.8 秒后才真正 seek）
  Duration? _pendingSeek;
  Timer? _seekTimer;

  EngineState get _state => _engine?.state.value ?? const EngineState();

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // 视频画面要实时更新：播放时调整窗口大小不用界面快照
    DesignScale.snapshotAllowed.value = false;
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_started && _state.playing) _report();
    });
    _start();
    _armSleepTimer();
    _focus.addListener(_keepFocus);
    // 电视：播放时暂停后台索引同步，不和播放抢带宽和 CPU
    if (PlatformProfile.isTv) {
      _holdsIndexSync = true;
      IndexSyncGate.hold();
    }
    WidgetsBinding.instance.addObserver(this);
    _autoArrived;
    // Windows：记下进播放页前窗口是不是全屏，退出播放时恢复成那样（播放页里进出全屏不影响首页等其他页面）。
    // 连播下一集、换服务器时由上一个播放页交接过来
    _entryFullScreen = _carriedEntryFullScreen ?? windowFullScreen.value;
    _carriedEntryFullScreen = null;
    // 最大化也一样：播放页里点最大化 / 还原，回到首页时恢复成进来前的样子
    _entryMaximized = _carriedEntryMaximized ?? windowMaximized.value;
    _carriedEntryMaximized = null;
    // 「开始播放时全屏」
    if (isDesktopWindow && DesktopPrefs.instance.fullScreenOnPlay.value && !MiniPlayerWindow.active.value) {
      if (!windowFullScreen.value) unawaited(setWindowFullScreen(true));
    }
    // Windows 关闭到托盘时暂停（窗口看不见了，不在后台继续放）
    DesktopTray.instance.hiddenToTray.addListener(_onHiddenToTray);
  }

  bool _holdsIndexSync = false;

  /// 进播放页前窗口是不是全屏（退出播放时恢复）
  bool _entryFullScreen = false;

  /// 连播 / 换服务器到下一个播放页：交接 [_entryFullScreen]
  static bool? _carriedEntryFullScreen;

  /// 进播放页前窗口是不是最大化（退出播放时恢复）
  bool _entryMaximized = false;
  static bool? _carriedEntryMaximized;

  /// 这一集是自动连播过来的
  late final bool _autoArrived = () {
    final v = _arrivingByAutoPlay;
    _arrivingByAutoPlay = false;
    if (v) {
      _autoPlayStreak++;
    } else {
      _autoPlayStreak = 0;
    }
    return v;
  }();

  /// 片尾自动下一集的倒计时（秒）；null = 没有倒计时
  int? _nextCountdown;
  bool _autoNextPending = false;
  Timer? _countdownTimer;

  /// 片尾自动下一集：显示「下一集」按钮，同时开始 3 秒倒计时，倒计时结束播放下一集
  static const nextCountdownSeconds = 3;

  /// 片尾自动模式：先倒计时，OK / 回车立即播放，返回取消（docs/07 §3.3）
  void _startNextCountdown() {
    if (_nextEpisode == null || _nextCountdown != null || SleepTimer.endOfItem || _sleepStopped) return;
    setState(() => _nextCountdown = nextCountdownSeconds);
    _countdownTimer?.cancel();
    _skipFadeTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      final left = (_nextCountdown ?? 0) - 1;
      if (left <= 0) {
        t.cancel();
        _goNext(auto: true);
      } else {
        setState(() => _nextCountdown = left);
      }
    });
  }

  void _playNextNow() => _goNext(auto: false);

  void _cancelNextCountdown() {
    _countdownTimer?.cancel();
    setState(() => _nextCountdown = null);
    showToast('已取消自动播放下一集');
  }

  void _goNext({required bool auto}) {
    _countdownTimer?.cancel();
    // 睡眠定时已到点 / 设了「本集播完」（可能是倒计时开始后才设的）：不自动进下一集
    if (auto && (_sleepStopped || SleepTimer.endOfItem)) return;
    final next = _nextEpisode;
    if (next == null || !mounted) return;
    if (auto) _arrivingByAutoPlay = true;
    _handoffTo('/play/${widget.serverId}/${next.id}?pos=0&resume=1');
  }

  /// 连续自动播放 3 集没人操作：暂停，问还在不在看
  Future<void> _askStillWatching() async {
    if (!mounted) return;
    await _engine?.pause();
    if (!mounted) return;
    var exit = false;
    await _menu(
      () => showContextMenu(
        context,
        anchored: true,
        title: '还在观看吗？已经连续自动播放了 $_autoPlayStreak 集',
        actions: [
          MenuAction('继续观看', Icons.play_arrow_rounded, () {
            _autoPlayStreak = 0;
            _engine?.play();
          }),
          MenuAction('退出播放', Icons.close_rounded, () => exit = true),
        ],
      ),
    );
    if (exit && mounted) context.pop();
  }

  void _onHiddenToTray() {
    if (DesktopTray.instance.hiddenToTray.value && _state.playing) _engine?.pause();
  }

  /// 焦点离开了播放页（按钮、面板卡片、跳过按钮消失时会落到页面的空容器上）而没有弹出菜单：
  /// 收回到画面上。不然遥控器按键都到不了播放页，暂停、快进都没反应（电视上「丢失指针」）
  void _keepFocus() {
    if (_focus.hasFocus) return;
    scheduleMicrotask(() {
      if (!mounted || _focus.hasFocus) return;
      // 菜单、对话框盖在上面时焦点在它们那里，不抢
      if (ModalRoute.of(context)?.isCurrent != true) return;
      _focus.requestFocus();
    });
  }

  // ───────────────────────── 内核 ─────────────────────────

  /// 磁盘缓存目录（进入播放页时准备好）
  String? _cacheDir;

  /// 播放器直接切到下一集 / 其他服务器的版本（关闭时保留预加载数据）
  bool _handoff = false;

  EngineOptions get _options {
    final p = ref.read(configProvider).playback;
    return EngineOptions(
      autoFrameRate: p.autoFrameRate,
      tunneling: p.tunneling,
      bufferBytes: p.bufferMb * 1024 * 1024,
      cacheDir: _cacheDir,
      hardwareDecoding: p.mpvHardwareDecoding,
    );
  }

  PlayerEngine _createEngine({bool forceMpv = false, bool forceExo = false}) {
    final fake = PlayerPage.debugEngineFactory;
    if (fake != null) return fake(_options);
    final p = ref.read(configProvider).playback;
    final useExo = ExoEngine.supported && (forceExo || (!forceMpv && p.engine != EnginePreference.mpv));
    return useExo ? ExoEngine(options: _options) : MpvEngine(options: _options);
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

  /// 最后一次确定的播放位置：起播时是续播位置，播放中跟着内核走，拖动 / 快进后是目标位置。
  /// 内核刚起播还没跳到续播位置、关闭 / 停下时会报 0：上报不能用这个 0
  /// （用 0 上报会把服务器上这一集的进度清掉，继续观看里就没有了，连之前的记录也一起没了）
  Duration _lastPosition = Duration.zero;

  /// 上报给服务器的位置：内核报 0 时用 [_lastPosition]（真的拖回开头时 [_lastPosition] 也是 0）
  Duration get _reportPosition => _state.position > Duration.zero ? _state.position : _lastPosition;

  /// 这次打开的媒体是否已经按「默认字幕」设置挑过字幕（每次打开 / 换源只挑一次，之后用户手动切换为准）
  bool _subtitlePicked = false;

  void _pickDefaultSubtitle(EngineState s) {
    if (_subtitlePicked) return;
    // 等字幕轨列表出来再挑：内核的播放状态和轨道列表是分开上报的，开始播放时列表可能还是空的。
    // 没有字幕轨的片子不用挑，一直等着也没有影响
    if (s.subtitleTracks.isEmpty) return;
    _subtitlePicked = true;
    final (change, track) = pickSubtitle(s.subtitleTracks, ref.read(configProvider).playback.subtitlePreference);
    // 不和 s.subtitle 比较：当前选中的轨道也是单独上报的，可能还没到（「不显示」时必须真的发关闭命令）
    if (change) unawaited(_engine?.selectSubtitle(track));
  }

  /// 打开时要求的起播位置（续播、跳过片头直接起播）：确认内核真的从这里开始。有的片源 / 内核会忽略起播位置
  /// 从头播放，这时补一次跳转（最多两次）。用户自己拖动进度后不再管
  Duration? _expectStart;
  int _startFixes = 0;
  DateTime _startFixAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 返回 true：起播位置还没生效（已补跳转），这次的位置不要拿去判断片头片尾
  bool _checkStart(EngineState s) {
    final want = _expectStart;
    if (want == null || s.duration <= Duration.zero) return false;
    if (s.position >= want - const Duration(seconds: 3)) {
      _expectStart = null;
      return false;
    }
    // 内核刚打开时先报 0，随后才跳到起播位置：开始走动（过了 1 秒）还在前面才算被忽略了
    if (!s.playing || s.position < const Duration(seconds: 1)) return true;
    if (DateTime.now().difference(_startFixAt) < const Duration(seconds: 2)) return true;
    if (_startFixes >= 2) {
      debugPrint('[play] 起播位置 ${want.inSeconds}s 没有生效，停在 ${s.position.inSeconds}s');
      _expectStart = null;
      // 起播直接跳过的片头其实没跳成：交回片头片尾逻辑重新处理（自动再跳一次，还不行就显示按钮）
      final skipped = _startupSkipped;
      if (skipped != null) {
        _startupSkipped = null;
        _segments?.reopen(skipped);
      }
      return false;
    }
    _startFixes++;
    _startFixAt = DateTime.now();
    debugPrint('[play] 起播位置 ${want.inSeconds}s 被忽略（现在 ${s.position.inSeconds}s），补一次跳转');
    _engine?.seek(want);
    return true;
  }

  void _onEngineState() {
    final s = _state;
    if ((s.video.hdr != null) != _appliedHdr) _applySubtitleBrightness(_engine);
    _pickDefaultSubtitle(s);
    final startPending = _checkStart(s);
    if (s.position > Duration.zero && (s.duration <= Duration.zero || s.position <= s.duration)) {
      _lastPosition = s.position;
    }
    // 开始播放前内核报的位置可能还是 0（续播时还没跳到上次的位置），不能拿来判断片头
    // 文件还没加载好（时长未知）时的位置也不算：这时发出的跳转会被内核丢掉
    if ((_started || s.playing) && s.duration > Duration.zero && !startPending) _segments?.onPosition(s.position);
    _limitReadahead(s.position);
    // 预加载下一集：看到 85%，或离片尾开始不到 1 分钟（片尾比较长的剧 85% 时可能已经在片尾里）
    final credits = _segmentList.where((x) => x.type == SegmentType.credits).firstOrNull;
    if (!_nextPreloading &&
        s.duration > Duration.zero &&
        (s.position.inMilliseconds > s.duration.inMilliseconds * 0.85 ||
            (credits != null && s.position >= credits.start - const Duration(minutes: 1)))) {
      _preloadNext();
    }
    if (_nextPreloading &&
        !_nextChecking &&
        s.duration > Duration.zero &&
        (s.duration - s.position < const Duration(seconds: 90) || (credits != null && s.position >= credits.start)) &&
        (_nextCheckedAt == null || DateTime.now().difference(_nextCheckedAt!) > const Duration(seconds: 15))) {
      _refreshNext(s.duration - s.position);
    }
    if (s.playing != _wasPlaying) {
      _wasPlaying = s.playing;
      if (!_started && s.playing) {
        _started = true;
        _report(start: true);
        if (_autoArrived && _autoPlayStreak >= 3 && ref.read(configProvider).playback.askStillWatching) {
          unawaited(_askStillWatching());
        }
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
    if (_started || !mounted) return;
    if (await _failover()) return;
    if (mounted) setState(() => _error = e.message);
  }

  /// 开播前当前版本打不开：按资源排序换到下一个没试过的版本（同服务器换源，或换到其他服务器从当前进度继续）。
  /// 返回 false 表示没有可换的版本，由调用方显示错误。
  Future<bool> _failover() async {
    if (_failingOver || _started) return false;
    _failingOver = true;
    try {
      final current = _source;
      if (current != null) _tried.add('${widget.serverId}/${current.id}');
      showToast('当前版本无法播放，正在尝试其他版本…');
      final all = await ref
          .read(sourceOptionsProvider((serverId: widget.serverId, itemId: widget.itemId)).future)
          .timeout(const Duration(seconds: 15));
      if (!mounted || _started) return false;
      final next = nextFailoverOption(visibleSourceOptions(ref.read(configProvider), all), _tried);
      if (next == null) return false;
      _tried.add(failoverKey(next));
      final at = Duration(milliseconds: widget.startMs);
      showToast('已切换到 ${next.source.resolutionLabel} ${next.source.rangeLabel} · ${next.serverName}');
      if (next.serverId == widget.serverId && next.item.id == widget.itemId) {
        setState(() => _error = null);
        // 不等待：新版本再失败时会再次进入 _failover（此时本次的 _failingOver 已复位）
        unawaited(_start(sourceId: next.source.id, at: at));
      } else {
        final tried = Uri.encodeComponent(_tried.join(','));
        _handoffTo('${next.playRoute(position: at)}&tried=$tried');
      }
      return true;
    } catch (e) {
      debugPrint('failover: $e');
      return false;
    } finally {
      _failingOver = false;
    }
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
    _lastPosition = at;
    _subtitlePicked = false;
    _expectStart = at > const Duration(seconds: 3) ? at : null;
    _startFixes = 0;
    _startFixAt = DateTime.fromMillisecondsSinceEpoch(0);
    await engine.open(EngineMedia(url: req.url, headers: headers, userAgent: req.userAgent, start: at));
    // 打开的过程中睡眠定时到点了（内核打开后会自动开始播）：立即暂停
    if (_sleepStopped) await engine.pause();
    if (PlatformProfile.isDesktop) await engine.setVolume(_muted ? 0 : _volume);
    await _applyDisplay(engine);
  }

  /// 起播位置。继续播放（[PlayerPage.resume]）时用服务器上这一集最新的进度：
  /// 卡片上的进度可能是缓存的旧数据，别的设备看得更靠后时以服务器为准；已经看完的（服务器进度为 0）从头播。
  /// 取不到最新数据（服务器慢、出错）时用卡片带来的位置，最多等 3 秒，不拖慢起播
  Future<Duration> _resumeFrom(Future<MediaItem> fresh) async {
    final fallback = Duration(milliseconds: widget.startMs);
    if (!widget.resume) return fallback;
    try {
      final item = await fresh.timeout(const Duration(seconds: 3));
      final carriedAt = widget.progressAt;
      if (carriedAt != null) {
        final at = PlayHistory.lastPlayed(item);
        final newer = at != null && at.millisecondsSinceEpoch > carriedAt;
        return newer && !item.played ? item.position : (newer ? Duration.zero : fallback);
      }
      // 服务器上是 0 又没标看完：多半是这台还没收到进度（上报没发出去、刚换过版本），用带来的位置，不从头播
      if (item.position == Duration.zero && !item.played) return fallback;
      if (item.position != fallback) {
        AppLog.add('[play] 续播位置以服务器为准：${formatClock(item.position)}（卡片上是 ${formatClock(fallback)}）');
      }
      return item.position;
    } catch (_) {
      return fallback;
    }
  }

  // ───────────────────────── 音量（Windows） ─────────────────────────

  /// 当前音量与静音（Windows；电视用遥控器调系统音量）。改动后稍等再存进设置，滚轮连续调时不反复写盘
  late double _volume = ref.read(configProvider).playback.volume;
  late bool _muted = ref.read(configProvider).playback.muted;
  Timer? _volumeSave;

  /// 超过 100% 是音量增强（最高 [maxVolume]）。从 100% 以下调上来时先停在 100%，要再按一次才进入增强；
  /// 按住 ↑ 不放（[repeat]）也停在 100%，免得一下子变得很响
  void _setVolume(double volume, {bool? muted, bool repeat = false}) {
    if (!PlatformProfile.isDesktop) return;
    var v = (volume * 100).round().clamp(0, (maxVolume * 100).round()) / 100;
    if (v > 1 && (_volume < 1 || (repeat && _volume <= 1))) v = 1;
    // 调大音量时自动取消静音
    final m = muted ?? (_muted && v <= _volume);
    setState(() {
      _volume = v;
      _muted = m;
    });
    _engine?.setVolume(m ? 0 : v);
    showToast(
      m ? '静音' : '音量 ${(v * 100).round()}%${v > 1 ? '（增强）' : ''}',
      duration: const Duration(milliseconds: 1200),
    );
    _volumeSave?.cancel();
    _volumeSave = Timer(const Duration(milliseconds: 800), _saveVolume);
  }

  void _saveVolume() {
    final v = _volume, m = _muted;
    final store = _container?.read(configProvider.notifier);
    if (store == null) return;
    try {
      store.update(
        (c) => c.copyWith(
          playback: c.playback.copyWith(volume: v, muted: m),
        ),
      );
    } on StateError catch (_) {}
  }

  void _toggleMute() => _setVolume(_volume, muted: !_muted);

  // ───────────────────────── 打开媒体 ─────────────────────────

  Future<void> _start({String? sourceId, Duration? at}) async {
    try {
      final client = ref.read(serverClientProvider(widget.serverId));
      if (client == null) throw const MediaServerException('服务器不存在');
      _client = client;
      // 并行：创建播放内核、取条目信息、取播放信息（详情页 / 首页已预加载时直接命中缓存）
      _cacheDir ??= await PlaybackCache.dir();
      final engineReady = _engine == null ? _attachEngine(_createEngine()) : Future<void>.value();
      // 条目（要用其中的续播位置）：10 分钟内从服务器取到过的直接用（首页继续观看、详情页、集列表都会取），
      // 不用在起播前再等一次单条详情；这台设备上报过进度后会重新取
      final recent = _item ?? client.recentItem(widget.itemId);
      // 已下载完：直接播本地文件，不请求播放信息（没有网络也能看）。下载列表启动时就在读，这里不等它
      final downloads = Downloads.instance;
      final downloaded = downloads.loaded
          ? downloads.playable(
              widget.serverId,
              widget.itemId,
              account: accountScope(client.server),
              sourceId: sourceId ?? widget.sourceId,
            )
          : null;
      // 儿童模式下看不到的条目不走本地文件（和列表里的过滤一致）
      final local = downloaded != null && itemVisible(ref.read(configProvider), downloaded.item) ? downloaded : null;
      final itemFuture = recent != null
          ? Future.value(recent)
          : local != null
          ? client.item(widget.itemId).timeout(const Duration(seconds: 3)).catchError((Object _) => local.item)
          : client.item(widget.itemId);
      itemFuture.ignore();
      // 剧集的剧信息和条目一起提前取（片头跳过起播、片头片尾查询都要用）
      itemFuture.then((it) {
        if (it.kind == MediaKind.episode && it.seriesId != null) _seriesItem(client, it.seriesId!).ignore();
      }, onError: (_) {});
      final info = local != null
          ? (sources: [local.source], playSessionId: null)
          : await PlaybackPreloader.info(client, widget.serverId, widget.itemId);
      if (info.sources.isEmpty) throw const MediaServerException('没有可播放的资源');
      final wanted = sourceId ?? widget.sourceId;
      final source = info.sources.where((s) => s.id == wanted).firstOrNull ?? info.sources.first;
      _source = source;
      _knownSources = info.sources;
      _request = local != null
          ? PlaybackRequest(url: Uri.file(local.path), headers: const {}, userAgent: '')
          : client.stream(source, playSessionId: info.playSessionId);
      if (local != null) AppLog.add('[play] 播放已下载的文件 ${local.path}');
      if (!mounted) return;
      setState(() {
        _source = source;
        _playSessionId = info.playSessionId ?? newPlaySessionId();
        _error = null;
      });
      final introStart = _introSkipStart(itemFuture, client, source);
      await engineReady;
      var from = at ?? await _resumeFrom(itemFuture);
      if (from == Duration.zero) {
        // 最多多等半秒（通常是本机读取，几毫秒）；拿不到就照常从头播，开播后再查、再跳
        final skipTo = await introStart.timeout(const Duration(milliseconds: 500), onTimeout: () => null);
        if (skipTo != null && mounted) {
          from = skipTo.end;
          _startupSkipped = skipTo;
          debugPrint(
            'segments: 起播直接跳过片头（自动模式）${skipTo.start.inSeconds}-${skipTo.end.inSeconds}s，从 ${skipTo.end.inSeconds}s 打开',
          );
          showToast('已为您跳过片头，如需调整请到「设置 → 片头片尾」', duration: const Duration(seconds: 4));
        }
      }
      await _openCurrent(from);
      _item = await itemFuture;
      if (mounted) setState(() {});
      unawaited(_beginSegments());
      unawaited(_beginDanmaku());
      unawaited(_loadChapters(client));
      unawaited(_loadTrickplay(client, source));
      ref.read(configProvider.notifier).updateServer(widget.serverId, (s) => s.copyWith(lastAccessAt: DateTime.now()));
    } catch (e) {
      // 拿不到播放信息 / 打不开：先自动换其他版本，没有可换的才显示错误
      if (!mounted) return;
      if (!_started && await _failover()) return;
      if (mounted) setState(() => _error = e.toString());
    }
  }

  // ───────────────────────── 进度上报 ─────────────────────────

  void _report({bool start = false, String event = 'TimeUpdate'}) {
    final client = _client, source = _source;
    if (client == null || source == null || _stopped) return;
    final pos = _reportPosition;
    // 本机也记一份上次播放时间（部分服务器的继续观看不带 LastPlayedDate）。只在开始和停止时记：
    // 每次进度上报（10 秒一次）都记的话，安卓上每次都要把整个设置文件重写到闪存，低端盒子会卡一下
    if (start) PlayHistory.record(widget.serverId, widget.itemId, scope: accountScope(client.server));
    if (start) {
      client.reportStart(source, pos, _playSessionId);
    } else {
      client.reportProgress(source, pos, _playSessionId, paused: !_state.playing, event: event);
    }
  }

  /// [completed]：播到了结尾（按片长上报，服务器据此标记为已看）
  void _reportStopped({bool completed = false}) {
    if (_stopped) return;
    _stopped = true;
    final client = _client, source = _source;
    if (client != null && source != null && _started) {
      // 位置在这里取好：后面是异步的，那时播放器可能已经关了，读到的是 0
      final duration = _state.duration > Duration.zero ? _state.duration : (source.duration ?? Duration.zero);
      final position = completed && duration > Duration.zero ? duration : _reportPosition;
      AppLog.add(
        '[play] 停止上报 ${widget.itemId} 位置 ${formatClock(position)} / ${formatClock(duration)}${completed ? '（播完）' : ''}',
      );
      PlayHistory.record(widget.serverId, widget.itemId, scope: accountScope(client.server));
      // 已下载的条目在本机也记一份进度（离线时下载页从这里继续播）
      final total = duration.inMilliseconds;
      Downloads.instance.recordProgress(
        widget.serverId,
        widget.itemId,
        position,
        account: accountScope(client.server),
        played: completed || (total > 0 && position.inMilliseconds >= total * 0.9),
      );
      // 继续观看先按本机的进度显示（不等服务器刷新回来）；看到 90% 以上服务器会标为已看，这里也移出。
      // 这里常在页面销毁过程中，不能马上改 provider：放到下一轮再写
      final item = _item;
      if (item != null && (item.kind == MediaKind.movie || item.kind == MediaKind.episode)) {
        final watched =
            completed || (duration > Duration.zero && position.inMilliseconds >= duration.inMilliseconds * 0.9);
        final local = item.withPlayState(position: position, played: watched, lastPlayed: DateTime.now());
        final container = _container;
        Future(() {
          try {
            container?.read(localPlaysProvider.notifier).record(local);
          } on StateError catch (_) {}
        });
      }
      // 页面销毁时不能再用 ref（Riverpod 会抛错并打断后续的关闭播放器），用提前保存的容器；
      // 等服务器记下进度后再刷新继续观看 / 详情
      final container = _container;
      final key = (serverId: widget.serverId, itemId: widget.itemId);
      // 先在本机存一份，服务器收到后删掉：上报发完之前应用就被关掉（退出后马上关应用、更新）时，下次启动补发
      final pending = PendingPlayReport(
        serverId: widget.serverId,
        account: accountScope(client.server),
        itemId: widget.itemId,
        sourceId: source.id,
        position: position,
        at: DateTime.now(),
        playSessionId: _playSessionId,
      );
      final session = _playSessionId;
      Future(() async {
        await PendingPlayReports.add(pending);
        if (await client.reportStopped(source, position, session)) await PendingPlayReports.done(pending);
      }).catchError((Object _) {}).whenComplete(() {
        // 应用正在关闭（容器已销毁）时不再刷新
        try {
          final refresh = container?.read(mediaFeedRefreshProvider.notifier);
          refresh?.refresh(MediaFeedKind.resume);
          // 播完的集会从继续观看移到观看记录：两边都刷新
          refresh?.refresh(MediaFeedKind.recentlyPlayed);
          container?.invalidate(itemProvider(key));
        } on StateError catch (_) {}
      });
    }
  }

  // ───────────────────────── 片头片尾 ─────────────────────────

  /// 片头片尾查询的代次：换源 / 换集后，旧的查询结果作废
  int _segmentGen = 0;

  /// 当前播放的片段查询（手动标记按它的「剧 + 季」/ 电影保存）与这一季 / 这部电影的手动标记
  SegmentQuery? _segmentQuery;
  ManualMark _manualMark = const ManualMark();

  /// 换源开始时立即停用旧版本的跳过规则、提示和进度条标记（新版本的时间轴可能不同）
  void _resetSegments() {
    _segmentGen++;
    _segmentQuery = null;
    _segments?.dispose();
    _segments = null;
    _creditsStart = null;
    _startupSkipped = null;
    // 换版本时内核会沿用：先把上一个版本设的预读上限恢复掉
    if (_readaheadSecs != null) _engine?.setReadaheadLimit(null);
    _readaheadSecs = null;
    if (mounted) {
      setState(() {
        _skipPrompt = null;
        _segmentList = const [];
      });
    }
  }

  SegmentQuery _segmentQueryFor(MediaItem item, MediaItem title, MediaSourceInfo source, Duration duration) =>
      SegmentQuery(
        titleKey: titleKeyOf(title),
        kind: item.kind == MediaKind.movie ? SegmentMediaKind.movie : SegmentMediaKind.episode,
        duration: duration,
        tmdbId: int.tryParse(title.tmdbId ?? ''),
        imdbId: title.imdbId,
        season: item.seasonNumber,
        episode: item.episodeNumber,
        sourceKey: '${widget.serverId}/${source.id}',
      );

  /// 从头播放、片头设为自动跳过时，起播前就知道片头在哪（手动标记，或之前查过的缓存）：
  /// 直接从片头结束处打开，比从头加载再跳快，也不会先闪一下片头。不联网查询，拿不到就从头播
  Future<Segment?> _introSkipStart(Future<MediaItem> itemFuture, EmbyClient client, MediaSourceInfo source) async {
    try {
      final item = await itemFuture;
      if (item.kind != MediaKind.movie && item.kind != MediaKind.episode) return null;
      final settings = await ref.read(segmentSettingsProvider.future);
      if (settings.intro != SegmentSkipMode.auto) return null;
      final title = item.kind == MediaKind.episode && item.seriesId != null
          ? await _seriesItem(client, item.seriesId!)
          : item;
      final duration = source.duration ?? item.runtime ?? Duration.zero;
      if (duration <= Duration.zero || !mounted) return null;
      final query = _segmentQueryFor(item, title, source, duration);
      final mark = await ManualSegmentStore.load(query) ?? const ManualMark();
      final resolver = await playbackSegmentResolver(ref, client, item.id);
      final cached = await resolver.cached(query) ?? const [];
      final controller = SegmentSkipController(query: query, settings: settings)
        ..segments = mergeManualSegments(cached, mark.segmentsFor(duration));
      return controller.autoIntroAtStart();
    } catch (_) {
      return null;
    }
  }

  /// 当前设给内核的预读上限（秒，null = 不限制）
  int? _readaheadSecs;

  /// 片尾会被自动跳到下一集时，预读只到片尾开始后几秒（留给「下一集」倒计时），不下载用不到的片尾，
  /// 省流量和服务器带宽。离片尾还远（15 分钟以上）时不用管，缓冲上限本来就到不了；拖进片尾后立即恢复
  void _limitReadahead(Duration position) {
    // 片尾开始时自动跳过已经触发（正在「下一集」倒计时）：倒计时期间仍然只预读到倒计时结束；取消倒计时后恢复
    final pending = _segments?.prefetchLimit;
    if (pending != null) _creditsStart = pending;
    final start = pending ?? (_nextCountdown != null ? _creditsStart : null);
    int? want;
    if (start != null) {
      final end = start + const Duration(seconds: nextCountdownSeconds + 2);
      if (position < end) {
        final secs = ((end - position).inMilliseconds / 1000).ceil();
        if (secs < 15 * 60) want = secs;
      }
    }
    if (want == _readaheadSecs) return;
    _readaheadSecs = want;
    _engine?.setReadaheadLimit(want == null ? null : Duration(seconds: want));
  }

  /// 起播前就跳过了的片头（直接从它的结束处打开）
  Segment? _startupSkipped;

  /// 最近一次会自动跳到下一集的片尾开始位置
  Duration? _creditsStart;

  Future<void> _beginSegments() async {
    final gen = ++_segmentGen;
    final item = _item, client = _client, source = _source;
    if (item == null || client == null || source == null) return;
    if (item.kind != MediaKind.movie && item.kind != MediaKind.episode) return;
    try {
      final settings = await ref.read(segmentSettingsProvider.future);
      // 剧集的 TMDB / IMDb ID 在剧上（第三方数据库按"剧 ID + 季 + 集"查询）
      var title = item;
      var hasNext = false;
      if (item.kind == MediaKind.episode && item.seriesId != null) {
        final results = await Future.wait([
          _seriesItem(client, item.seriesId!).then<Object?>((v) => v, onError: (_) => null),
          _resolveNextEpisode(),
        ]);
        if (results[0] is MediaItem) title = results[0]! as MediaItem;
        hasNext = results[1] != null;
      }
      final duration = source.duration ?? item.runtime ?? _state.duration;
      if (duration <= Duration.zero || !mounted) return;
      final query = _segmentQueryFor(item, title, source, duration);
      final resolver = await playbackSegmentResolver(ref, client, item.id);
      final mark = await ManualSegmentStore.load(query) ?? const ManualMark();
      if (!mounted || gen != _segmentGen || _source?.id != source.id) return;
      _segmentQuery = query;
      _manualMark = mark;
      _segments?.dispose();
      _segments =
          SegmentPlaybackSession(
            resolver: resolver,
            seek: (to) async => _engine?.seek(to),
            nextEpisode: () async {
              if (!mounted) return;
              // 自动模式先倒计时；用户按了「下一集」按钮直接播放
              if (_autoNextPending) {
                _autoNextPending = false;
                _startNextCountdown();
              } else {
                _goNext(auto: false);
              }
            },
            onPrompt: (action) {
              if (!mounted || _samePrompt(action, _skipPrompt)) return;
              if (action != null) debugPrint('segments: 显示跳过按钮 ${_describeSkip(action)}');
              setState(() {
                _skipPrompt = action;
                _skipFaded = false;
              });
              _skipFadeTimer?.cancel();
              if (action != null && PlatformProfile.isDesktop) {
                _skipFadeTimer = Timer(const Duration(seconds: skipButtonSeconds), () {
                  if (mounted) setState(() => _skipFaded = true);
                });
              }
            },
            onResolution: (r) {
              // 写进日志：没跳过时能看出是没查到数据、来源出错，还是查到了但模式是「显示按钮」
              debugPrint(
                'segments: ${item.name} tmdb=${query.tmdbId} imdb=${query.imdbId} '
                's${query.season}e${query.episode} ${duration.inSeconds}s → '
                '${r.segments.isEmpty ? '没有片段' : r.segments.map((s) => '${s.type.name}@${s.provider} ${s.start.inSeconds}-${s.end.inSeconds}s').join(', ')}'
                '${r.fromCache ? '（缓存）' : ''}${r.failures.isEmpty ? '' : ' 失败：${r.failures.map((k, v) => MapEntry(k, v.name))}'}'
                ' 模式：片头=${settings.intro.name} 片尾=${settings.credits.name}',
              );
              if (mounted) setState(() => _segmentList = r.segments);
            },
            onAutoSkip: (action) {
              debugPrint('segments: 自动跳过 ${_describeSkip(action)}');
              if (action.kind == SegmentSkipActionKind.nextEpisode) {
                _autoNextPending = true;
              } else {
                showToast(_autoSkipText(action), duration: const Duration(seconds: 4));
              }
            },
            onActionError: (e) => debugPrint('segments: $e'),
            onLog: (m) => debugPrint('segments: $m'),
          )..begin(
            query,
            settings,
            hasNextEpisode: hasNext,
            position: _started ? _state.position : null,
            manual: mark.segmentsFor(duration),
            handled: [?_startupSkipped],
          );
    } catch (e) {
      debugPrint('segments unavailable: $e');
    }
  }

  // ───────────────────────── 弹幕 ─────────────────────────

  DanmakuClient? get _danmakuClient {
    final c = ref.read(configProvider).danmaku;
    return c.allServers.isEmpty ? null : DanmakuClient(c);
  }

  /// 起播后自动匹配：记住的手动选择 → 服务器自动匹配 → 按标题搜索
  Future<void> _beginDanmaku() async {
    final item = _item;
    final config = ref.read(configProvider).danmaku;
    if (item == null || _danmakuTarget != null) return;
    if (item.kind != MediaKind.movie && item.kind != MediaKind.episode) return;
    final target = _danmakuTarget = DanmakuTarget.of(item);
    _danmakuVisible = config.enabled;
    final choice = await DanmakuChoiceStore.get(target.key);
    if (choice != null) _danmakuChoice = choice;
    if (!config.ready) return;
    await _loadDanmaku(() async => resolveDanmaku(DanmakuClient(config), target, choice: choice));
  }

  Future<void> _loadDanmaku(Future<DanmakuTrack?> Function() load, {bool announce = false}) async {
    if (mounted) setState(() => _danmakuLoading = true);
    try {
      var track = await load();
      if (track != null && track.comments.isEmpty) track = null;
      if (!mounted) return;
      setState(() {
        _danmaku = track;
        _danmakuError = track == null ? '没有匹配到弹幕' : null;
      });
      if (track != null && (announce || _danmakuVisible)) {
        showToast('弹幕：${track.comments.length} 条 · ${track.source}');
      } else if (track == null && announce) {
        showToast('没有找到这一集的弹幕');
      }
    } catch (e) {
      debugPrint('danmaku: $e');
      if (mounted) setState(() => _danmakuError = '$e');
      if (announce) showToast('加载弹幕失败：$e');
    } finally {
      if (mounted) setState(() => _danmakuLoading = false);
    }
  }

  void _toggleDanmaku() {
    if (_danmaku == null && !_danmakuLoading) {
      _openDanmakuMenu();
      return;
    }
    setState(() => _danmakuVisible = !_danmakuVisible);
    showToast(_danmakuVisible ? '弹幕：开' : '弹幕：关');
  }

  Future<void> _setDanmakuShift(int ms) async {
    final target = _danmakuTarget;
    setState(() => _danmakuChoice = _danmakuChoice.copyWith(shiftMs: ms));
    showToast(ms == 0 ? '弹幕时间：不偏移' : '弹幕时间：${ms > 0 ? '延后' : '提前'} ${(ms.abs() / 1000).toStringAsFixed(1)} 秒');
    if (target != null) await DanmakuChoiceStore.set(target.key, _danmakuChoice);
  }

  String get _danmakuStatus {
    if (_danmakuLoading) return '加载中…';
    if (_danmaku != null) return '${_danmakuVisible ? '开' : '关'} · ${_danmaku!.comments.length} 条';
    if (ref.read(configProvider).danmaku.allServers.isEmpty) return '未配置服务器';
    return _danmakuError == null ? '未加载' : '未匹配';
  }

  String get _danmakuTitle => _danmaku == null ? '弹幕' : '弹幕 · ${_danmaku!.source}';

  Future<void> _openDanmakuMenu() async {
    if (_danmakuReady() == null) return;
    // 每次显示时重新生成：二级菜单里改了样式，回到这一级显示新的值
    await showContextMenu(context, anchored: true, title: _danmakuTitle, actionsBuilder: _danmakuItems);
    if (mounted && _adjusting == null) _focus.requestFocus();
  }

  /// 弹幕服务器和要找弹幕的那一集；没配置服务器时提示并返回 null
  (DanmakuClient, DanmakuTarget)? _danmakuReady() {
    final client = _danmakuClient;
    final target = _danmakuTarget ?? (_item == null ? null : DanmakuTarget.of(_item!));
    if (client == null || target == null) {
      showToast('还没有配置弹幕服务器：设置 → 接口与网络');
      return null;
    }
    _danmakuTarget ??= target;
    return (client, target);
  }

  List<MenuAction> _danmakuItems() {
    final ready = _danmakuReady();
    if (ready == null) return const [];
    final (client, target) = ready;

    final shift = _danmakuChoice.shiftMs;
    final style = ref.read(configProvider).danmaku;
    return [
      if (_danmaku != null)
        MenuAction(
          _danmakuVisible ? '隐藏弹幕' : '显示弹幕',
          _danmakuVisible ? Icons.speaker_notes_off_outlined : Icons.speaker_notes_outlined,
          _toggleDanmaku,
        ),
      // 显示样式：改完立即作用在屏幕上的弹幕，并保存到「设置 → 弹幕」
      _danmakuStyle('显示区域', Icons.height_rounded, DanmakuConfig.areaOptions, style.area, (c, v) => c.copyWith(area: v)),
      _danmakuStyle(
        '字号',
        Icons.format_size_rounded,
        DanmakuConfig.fontOptions,
        style.fontSize,
        (c, v) => c.copyWith(fontSize: v),
      ),
      _danmakuStyle(
        '不透明度',
        Icons.opacity_rounded,
        DanmakuConfig.opacityOptions,
        style.opacity,
        (c, v) => c.copyWith(opacity: v),
      ),
      _danmakuStyle(
        '滚动速度',
        Icons.speed_rounded,
        DanmakuConfig.speedOptions,
        style.speed,
        (c, v) => c.copyWith(speed: v),
      ),
      MenuAction('搜索「${target.title}」并选择', Icons.manage_search_rounded, () => _searchDanmaku(target.title)),
      MenuAction('按关键词搜索…', Icons.keyboard_rounded, () => _searchDanmakuByKeyword(target.title)),
      if (PlatformProfile.isDesktop)
        MenuAction(
          '时间偏移 · ${SliderSpec.danmakuShift.format(shift / 1000)}',
          Icons.schedule_rounded,
          () => _startAdjust(_Adjusting.danmakuShift),
        )
      else
        MenuAction.submenu(
          '时间偏移 · ${shift == 0 ? '无' : '${shift > 0 ? '+' : ''}${(shift / 1000).toStringAsFixed(1)} 秒'}',
          Icons.schedule_rounded,
          title: '弹幕时间偏移',
          items: () => [
            for (final d in const [-5000, -1000, -500, 500, 1000, 5000])
              MenuAction(
                '${d > 0 ? '延后' : '提前'} ${(d.abs() / 1000).toStringAsFixed(1)} 秒',
                d > 0 ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
                () => _setDanmakuShift(_danmakuChoice.shiftMs + d),
              ),
            MenuAction('重置', Icons.restart_alt_rounded, () => _setDanmakuShift(0)),
          ],
        ),
      MenuAction(
        '重新自动匹配',
        Icons.refresh_rounded,
        () => _loadDanmaku(() => resolveDanmaku(client, target, choice: _danmakuChoice), announce: true),
      ),
    ];
  }

  /// 弹幕样式（显示区域 / 字号 / 不透明度 / 速度）的二级菜单：选完回到弹幕菜单，方便接着调
  MenuAction _danmakuStyle(
    String title,
    IconData icon,
    List<(double, String)> options,
    double current,
    DanmakuConfig Function(DanmakuConfig, double) apply,
  ) => MenuAction.submenu(
    '$title · ${DanmakuConfig.labelOf(options, current)}',
    icon,
    title: '弹幕$title',
    items: () => [
      for (final (v, label) in options)
        MenuAction('$label${v == current ? '  ✓' : ''}', Icons.chat_outlined, () {
          if (!_danmakuVisible) setState(() => _danmakuVisible = true);
          ref.read(configProvider.notifier).update((c) => c.copyWith(danmaku: apply(c.danmaku, v)));
        }),
    ],
  );

  Future<void> _searchDanmakuByKeyword(String initial) async {
    final controller = TextEditingController(text: initial);
    String? keyword;
    await showFormDialog(
      context,
      title: '搜索弹幕',
      description: '输入作品名，比如中文名或别名',
      saveLabel: '搜索',
      children: [VTextField(label: '关键词', controller: controller, autofocus: true)],
      onSave: () async {
        keyword = controller.text.trim();
        return keyword!.isNotEmpty;
      },
    );
    controller.dispose();
    if (keyword != null && keyword!.isNotEmpty && mounted) await _searchDanmaku(keyword!);
    if (mounted) _focus.requestFocus();
  }

  /// 手动选择：作品列表 → 集列表；选中后记住（同一季后面几集自动用这个作品和集数偏移）
  Future<void> _searchDanmaku(String keyword) async {
    final client = _danmakuClient, target = _danmakuTarget;
    if (client == null || target == null) return;
    showToast('正在搜索弹幕「$keyword」…');
    List<DanmakuAnime> animes;
    try {
      animes = await client.search(keyword, season: target.season, movie: target.movie);
    } catch (e) {
      showToast('搜索弹幕失败：$e');
      return;
    }
    if (!mounted) return;
    if (animes.isEmpty) {
      showToast('没有搜到「$keyword」的弹幕');
      return;
    }
    await showContextMenu(
      context,
      anchored: true,
      title: '选择作品 · ${animes.length} 个结果',
      actions: [
        for (final a in animes.take(40))
          MenuAction(
            [
              a.title,
              if (a.episodeCount != null) '${a.episodeCount} 集',
              ?DanmakuClient.sourceLabel(a.server),
            ].join(' · '),
            Icons.movie_filter_outlined,
            () => _pickDanmakuEpisode(client, target, a),
          ),
      ],
    );
    if (mounted) _focus.requestFocus();
  }

  Future<void> _pickDanmakuEpisode(DanmakuClient client, DanmakuTarget target, DanmakuAnime anime) async {
    List<DanmakuEpisode> eps;
    try {
      eps = await client.episodes(anime);
    } catch (e) {
      showToast('获取集列表失败：$e');
      return;
    }
    if (!mounted || eps.isEmpty) {
      if (eps.isEmpty) showToast('这个作品没有可用的集');
      return;
    }
    final current = target.episode == null ? null : pickEpisode(eps, target.episode! + _danmakuChoice.offset);
    Future<void> choose(int i) async {
      final ep = eps[i];
      final offset = target.episode == null ? 0 : (ep.number ?? i + 1) - target.episode!;
      _danmakuChoice = DanmakuChoice(
        server: anime.server,
        animeId: anime.animeId,
        animeTitle: anime.title,
        offset: offset,
        shiftMs: _danmakuChoice.shiftMs,
      );
      await DanmakuChoiceStore.set(target.key, _danmakuChoice);
      _danmakuVisible = true;
      await _loadDanmaku(
        () => client.load(anime.server, ep.episodeId, source: '${anime.title} · ${ep.title}'),
        announce: true,
      );
    }

    if (eps.length == 1) return choose(0);
    await showContextMenu(
      context,
      anchored: true,
      title: '选择集 · ${anime.title}',
      actions: [
        for (var i = 0; i < eps.length; i++)
          MenuAction(
            '${eps[i].title}${identical(eps[i], current) ? '  ✓' : ''}',
            Icons.play_circle_outline_rounded,
            () => choose(i),
          ),
      ],
    );
    if (mounted) _focus.requestFocus();
  }

  static bool _samePrompt(SegmentSkipAction? a, SegmentSkipAction? b) =>
      identical(a, b) ||
      (a != null &&
          b != null &&
          a.segment.start == b.segment.start &&
          a.segment.type == b.segment.type &&
          a.kind == b.kind);

  static String _autoSkipText(SegmentSkipAction a) => switch (a.segment.type) {
    _ when a.kind == SegmentSkipActionKind.nextEpisode => '片尾：已自动播放下一集',
    SegmentType.intro => '已为您跳过片头，如需调整请到「设置 → 片头片尾」',
    SegmentType.recap => '已为您跳过前情提要，如需调整请到「设置 → 片头片尾」',
    SegmentType.credits => '已为您跳过片尾，如需调整请到「设置 → 片头片尾」',
    SegmentType.preview => '已自动跳过预告',
  };

  void _activateSkip() {
    final action = _skipPrompt;
    if (action == null) return;
    debugPrint('segments: 手动跳过 ${_describeSkip(action)}');
    _segments?.activate(action);
  }

  /// 写日志用：片段类型、范围、当前位置和动作
  String _describeSkip(SegmentSkipAction a) =>
      '${a.segment.type.name} ${a.segment.start.inSeconds}-${a.segment.end.inSeconds}s '
      '@${_state.position.inSeconds}s → '
      '${a.kind == SegmentSkipActionKind.nextEpisode ? '下一集' : '${a.target.inSeconds}s'}';

  void _handoffTo(String route) {
    _handoff = true;
    // 进播放页前的窗口状态交给下一个播放页（新页面先建好、这一页后销毁，所以在这里交接）
    _carriedEntryFullScreen = _entryFullScreen;
    _carriedEntryMaximized = _entryMaximized;
    context.pushReplacement(route);
  }

  Future<void> _preloadNext() async {
    _nextPreloading = true;
    final client = _client;
    try {
      final next = await _resolveNextEpisode();
      if (next == null || client == null) return;
      await PlaybackPreloader.preload(client, next, position: Duration.zero);
    } catch (_) {}
  }

  bool _nextChecking = false;
  DateTime? _nextCheckedAt;

  /// 快播完时确认下一集的播放信息和条目到切过去时仍在缓存里：85% 时预加载的播放信息只缓存 3 分钟，
  /// 播到结尾时常已过期，自动进下一集要重新请求（经反代 1~2 秒）。按剩余时间（最多算 90 秒，片尾自动跳过时更早切）
  /// 再留 30 秒余量：缓存撑不到那时就重新取，撑得到就不发请求。剩 90 秒内每 15 秒检查一次
  Future<void> _refreshNext(Duration remaining) async {
    _nextChecking = true;
    _nextCheckedAt = DateTime.now();
    final client = _client;
    try {
      final next = await _resolveNextEpisode();
      if (next == null || client == null || !PlaybackPreloader.enabled) return;
      final need =
          (remaining > const Duration(seconds: 90) ? const Duration(seconds: 90) : remaining) +
          const Duration(seconds: 30);
      await Future.wait([
        PlaybackPreloader.info(client, widget.serverId, next.id, maxAge: PlaybackPreloader.infoTtl - need),
        if (client.recentItem(next.id, maxAge: const Duration(minutes: 10) - need) == null) client.item(next.id),
      ]);
    } catch (_) {
    } finally {
      _nextChecking = false;
    }
  }

  Future<void> _onCompleted() async {
    _reportStopped(completed: true);
    final item = _item, client = _client;
    if (item == null || client == null || !mounted) return;
    // 睡眠定时「本集播完」/ 已到点：停在这里，不播下一集
    Future<bool> sleepStop() async {
      if (!SleepTimer.endOfItem && !_sleepStopped) return false;
      final toast = SleepTimer.endOfItem;
      SleepTimer.clear();
      _countdownTimer?.cancel();
      await _engine?.pause();
      if (toast) showToast('睡眠定时：本集已播完，已停止播放', duration: const Duration(seconds: 5));
      if (mounted) setState(() {});
      return true;
    }

    if (await sleepStop()) return;
    // 剧集自动播放下一集（季末接着播下一季第一集）
    final next = await _resolveNextEpisode();
    if (!mounted) return;
    // 查下一集的时候睡眠定时到点了 / 设了「本集播完」：同样停下
    if (await sleepStop() || !mounted) return;
    if (next != null) {
      _arrivingByAutoPlay = true;
      _countdownTimer?.cancel();
      _handoffTo('/play/${widget.serverId}/${next.id}?pos=0&resume=1');
      return;
    }
    context.pop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container ??= ProviderScope.containerOf(context, listen: false);
  }

  /// dispose 里不能用 ref，提前拿到容器
  ProviderContainer? _container;

  @override
  void dispose() {
    DesktopTray.instance.hiddenToTray.removeListener(_onHiddenToTray);
    WidgetsBinding.instance.removeObserver(this);
    _countdownTimer?.cancel();
    _sleepTimer?.cancel();
    // 退出播放就取消睡眠定时；连播下一集 / 换版本时按分钟的定时接着算，「本集播完」只管这一集
    if (_handoff) {
      SleepTimer.endOfItem = false;
    } else {
      SleepTimer.clear();
    }
    if (_volumeSave?.isActive ?? false) {
      _volumeSave!.cancel();
      _saveVolume();
    }
    if (_holdsIndexSync) IndexSyncGate.release();
    // 最先关闭播放器：后面任何一步出错都不能让视频在后台继续播放
    final engine = _engine;
    _engine?.state.removeListener(_onEngineState);
    final clear = _container?.read(configProvider).playback.clearCacheOnExit ?? true;
    final handoff = _handoff;
    Future(() async {
      try {
        await engine?.dispose();
      } finally {
        if (clear) await PlaybackCache.clear(keepPreload: handoff);
      }
    });
    _reportStopped();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    DesignScale.snapshotAllowed.value = true;
    for (final s in _engineSubs) {
      s.cancel();
    }
    _osdTimer?.cancel();
    _progressTimer?.cancel();
    _seekTimer?.cancel();
    _segments?.dispose();
    _focus.removeListener(_keepFocus);
    _focus.dispose();
    _playNode.dispose();
    _topNode.dispose();
    _skipFadeTimer?.cancel();
    // 退出播放时恢复窗口；连播下一集 / 换服务器时保持小窗
    // 退出播放时窗口恢复成进来前的样子：先退小窗，再恢复全屏和最大化
    // （连播 / 换服务器时已在 _handoffTo 交给下一个播放页）
    if (!handoff) {
      final full = _entryFullScreen, max = _entryMaximized;
      unawaited(() async {
        await MiniPlayerWindow.exit();
        if (!isDesktopWindow) return;
        await setWindowFullScreen(full);
        if (!full) await setWindowMaximized(max);
      }());
    }
    // 销毁过程中不能让别的组件重建：这一帧结束后再恢复标题栏
    scheduleMicrotask(() => windowImmersive.value = false);
    super.dispose();
  }

  // ───────────────────────── 操作 ─────────────────────────

  /// 焦点在控制层的按钮上（电视用遥控器移进去的，或 Windows 鼠标悬停）
  bool get _onControls => !_focus.hasPrimaryFocus && _focus.hasFocus;

  void _showOsd({bool sticky = false}) {
    // 调整字幕位置时控制层不出来，免得挡住画面
    if (_adjusting != null) return;
    _osdTimer?.cancel();
    if (!_osd && mounted) setState(() => _osd = true);
    if (!sticky) _armOsdTimer();
  }

  void _armOsdTimer() {
    _osdTimer?.cancel();
    _osdTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      // 打开面板、电视焦点在按钮上、鼠标停在控制栏上时不隐藏
      final busy = _panel != OsdPanel.none || (PlatformProfile.isTv && _onControls) || _hoverControls;
      if (busy || !_state.playing) {
        _armOsdTimer();
        return;
      }
      setState(() => _osd = false);
      if (_onControls) _focus.requestFocus();
    });
  }

  /// 电视按 ↓：显示控制层，焦点落在播放 / 暂停按钮上
  /// 电视按 ↑：显示控制层，焦点落在右上角第一个按钮（弹幕）上
  void _focusTop() => _focusControls(node: _topNode);

  void _focusControls({FocusNode? node}) {
    final target = node ?? _playNode;
    final visible = _osd;
    _showOsd();
    // 控制层已经显示：直接移焦点。还没显示：等它画出来（按钮不再被排除在焦点外）再移。
    // 只加帧后回调不会触发新的一帧——暂停时画面不变，焦点就一直移不过去，所以要确保有下一帧
    if (visible) {
      target.requestFocus();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) target.requestFocus();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _seekBy(Duration delta) {
    _expectStart = null;
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
      if (t != null) {
        _lastPosition = t;
        _engine?.seek(t);
      }
      if (mounted) setState(() => _pendingSeek = null);
      _report();
    });
  }

  /// 按住 ←→ 时越按越快（docs/07 §3.1）：头 1.5 秒每秒快进约 1 分钟，到 4 秒约 4 分钟，之后约 16 分钟。
  /// 按时间算而不是按重复次数算，不同遥控器的连发速度不同也一样快
  DateTime? _holdSince;
  DateTime? _lastHold;

  Duration _holdDelta(Duration step, bool repeat) {
    final now = PlayerPage.debugNow();
    if (!repeat) {
      _holdSince = _lastHold = now;
      return step;
    }
    final held = now.difference(_holdSince ?? now);
    final dt = now.difference(_lastHold ?? now).inMilliseconds.clamp(0, 250);
    _lastHold = now;
    final speed = held < const Duration(milliseconds: 1500)
        ? 60
        : held < const Duration(seconds: 4)
        ? 240
        : 960;
    return Duration(milliseconds: (speed * dt).clamp(1000, 60000).round());
  }

  static int? _digitOf(LogicalKeyboardKey key) {
    const rows = [
      [LogicalKeyboardKey.digit0, LogicalKeyboardKey.numpad0],
      [LogicalKeyboardKey.digit1, LogicalKeyboardKey.numpad1],
      [LogicalKeyboardKey.digit2, LogicalKeyboardKey.numpad2],
      [LogicalKeyboardKey.digit3, LogicalKeyboardKey.numpad3],
      [LogicalKeyboardKey.digit4, LogicalKeyboardKey.numpad4],
      [LogicalKeyboardKey.digit5, LogicalKeyboardKey.numpad5],
      [LogicalKeyboardKey.digit6, LogicalKeyboardKey.numpad6],
      [LogicalKeyboardKey.digit7, LogicalKeyboardKey.numpad7],
      [LogicalKeyboardKey.digit8, LogicalKeyboardKey.numpad8],
      [LogicalKeyboardKey.digit9, LogicalKeyboardKey.numpad9],
    ];
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].contains(key)) return i;
    }
    return null;
  }

  static const _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  void _setRate(double r) {
    _engine?.setRate(r);
    showToast('倍速 ${r}x', duration: const Duration(milliseconds: 1200));
  }

  void _stepRate(int dir) {
    final i = _rates.indexWhere((r) => r >= _state.rate - 0.001);
    final cur = i < 0 ? _rates.length - 1 : i;
    final next = (cur + dir).clamp(0, _rates.length - 1);
    _setRate(_rates[next]);
  }

  // ───────────────────────── HDR 字幕亮度、解码方式 ─────────────────────────

  /// 上次按哪种片源设置的字幕亮度（true = HDR）；null = 还没设置
  bool? _appliedHdr;

  /// HDR 片源用设置里的字幕亮度，SDR 片源保持原样（内核报出 HDR 信息后再设一次）
  void _applySubtitleBrightness(PlayerEngine? engine) {
    if (engine == null) return;
    final hdr = _state.video.hdr != null;
    _appliedHdr = hdr;
    final b = ref.read(configProvider).playback.hdrSubtitleBrightness;
    unawaited(engine.setSubtitleBrightness(hdr ? b : 1));
  }

  void _setHdrSubtitleBrightness(double b) {
    ref
        .read(configProvider.notifier)
        .update((c) => c.copyWith(playback: c.playback.copyWith(hdrSubtitleBrightness: b)));
    _applySubtitleBrightness(_engine);
    final pct = '${(b * 100).round()}%';
    showToast(_state.video.hdr != null ? 'HDR 字幕亮度：$pct' : 'HDR 字幕亮度：$pct（播放 HDR 片源时生效）');
  }

  void _setSubtitleLook(SubtitleLook look) {
    ref.read(configProvider.notifier).update((c) => c.copyWith(playback: c.playback.copyWith(subtitleLook: look)));
    unawaited(_engine?.setSubtitleLook(look));
  }

  /// mpv 硬解 / 软解切换：立即生效，按设备保存
  void _toggleHardwareDecoding() {
    final engine = _engine;
    if (engine == null || !engine.supportsDecoderSwitch) return;
    final on = !ref.read(configProvider).playback.mpvHardwareDecoding;
    ref.read(configProvider.notifier).update((c) => c.copyWith(playback: c.playback.copyWith(mpvHardwareDecoding: on)));
    unawaited(engine.setHardwareDecoding(on));
    showToast(on ? '已改为硬解' : '已改为软解（CPU 占用会变高，4K 片源可能卡顿）');
  }

  // ───────────────────────── 进度条缩略图 ─────────────────────────

  Trickplay? _trickplay;
  String? _trickplaySource;

  /// 换了版本才重新取（缩略图按媒体源生成）；服务器没生成就没有，照常只显示时间
  Future<void> _loadTrickplay(EmbyClient client, MediaSourceInfo source) async {
    if (_trickplaySource == source.id) return;
    _trickplaySource = source.id;
    if (mounted) setState(() => _trickplay = null);
    try {
      final t = await client.trickplay(widget.itemId, source.id);
      if (mounted && _trickplaySource == source.id) setState(() => _trickplay = t);
    } catch (e) {
      debugPrint('trickplay: $e');
      if (_trickplaySource == source.id) _trickplaySource = null; // 下次打开再试
    }
  }

  // ───────────────────────── 章节 ─────────────────────────

  /// 服务器上的章节（去掉片头片尾标记）；少于 2 个时不显示菜单
  List<ServerChapter> _chapters = const [];

  Future<void> _loadChapters(EmbyClient client) async {
    try {
      final list = chapterList(await client.chapters(widget.itemId));
      if (mounted) setState(() => _chapters = list);
    } catch (e) {
      debugPrint('chapters: $e');
    }
  }

  List<MenuAction> _chapterItems() {
    final current = currentChapterIndex(_chapters, _state.position);
    return [
      for (var i = 0; i < _chapters.length; i++)
        MenuAction(
          '${formatClock(_chapters[i].start)}  ${_chapters[i].name.isEmpty ? '第 ${i + 1} 章' : _chapters[i].name}'
          '${i == current ? '  ✓' : ''}',
          Icons.bookmark_border_rounded,
          () => _seekTo(_chapters[i].start),
        ),
    ];
  }

  // ───────────────────────── 睡眠定时 ─────────────────────────

  Timer? _sleepTimer;

  /// 按 [SleepTimer.deadline] 安排到点暂停（连播下一集时新的播放页接着算）
  void _armSleepTimer() {
    _sleepTimer?.cancel();
    final left = SleepTimer.remaining();
    if (left == null) return;
    _sleepTimer = Timer(left, _onSleep);
  }

  /// 睡眠定时已经到点：之后不再自动播下一集；还在打开媒体时，打开后立即暂停
  bool _sleepStopped = false;

  void _onSleep() {
    if (!mounted) return;
    SleepTimer.clear();
    _sleepStopped = true;
    // 片尾倒计时正在走：取消，不然倒计时结束会进下一集接着播
    _countdownTimer?.cancel();
    _nextCountdown = null;
    _engine?.pause();
    setState(() {});
    showToast('睡眠定时到了，已暂停播放', duration: const Duration(seconds: 5));
  }

  void _setSleep({int? minutes, bool endOfItem = false}) {
    _sleepStopped = false;
    if (minutes != null) {
      SleepTimer.setMinutes(minutes);
      showToast('$minutes 分钟后暂停播放');
    } else if (endOfItem) {
      SleepTimer.setEndOfItem();
      // 片尾倒计时已经在走：取消
      _countdownTimer?.cancel();
      _nextCountdown = null;
      showToast(_item?.kind == MediaKind.episode ? '本集播完后停止，不自动播下一集' : '播完后停止');
    } else {
      SleepTimer.clear();
      showToast('已关闭睡眠定时');
    }
    _armSleepTimer();
    setState(() {});
  }

  List<MenuAction> _sleepItems() {
    final minutes = SleepTimer.endOfItem ? null : SleepTimer.deadline;
    return [
      MenuAction('关闭${SleepTimer.active ? '' : '  ✓'}', Icons.timer_off_outlined, () => _setSleep()),
      MenuAction(
        '${_item?.kind == MediaKind.episode ? '本集播完' : '播完'}${SleepTimer.endOfItem ? '  ✓' : ''}',
        Icons.stop_circle_outlined,
        () => _setSleep(endOfItem: true),
      ),
      for (final m in SleepTimer.presets) MenuAction('$m 分钟', Icons.timer_outlined, () => _setSleep(minutes: m)),
      if (minutes != null) MenuAction('现在：${SleepTimer.label()}', Icons.bedtime_outlined, () {}),
    ];
  }

  // ───────────────────────── 音画同步 ─────────────────────────

  int get _audioDelayMs => ref.read(configProvider).playback.audioDelayMs;

  /// 音画同步：设为 [ms] 毫秒（正数 = 声音推后），立即生效并按设备保存
  void _setAudioDelay(int ms, {bool toast = true}) {
    final engine = _engine;
    if (engine == null) return;
    if (!engine.supportsAudioDelay) {
      showToast('当前播放内核不支持调整音画同步');
      return;
    }
    const limit = PlaybackConfig.audioDelayLimitMs;
    final v = ms.clamp(-limit, limit);
    engine.setAudioDelay(Duration(milliseconds: v));
    ref.read(configProvider.notifier).update((c) => c.copyWith(playback: c.playback.copyWith(audioDelayMs: v)));
    if (toast) showToast('音画同步：${SliderSpec.audioDelayLabel(v / 1000)}');
  }

  // ───────────────────────── 字幕延迟 / 大小、画面比例 ─────────────────────────

  Duration _subDelay = Duration.zero;

  void _shiftSubtitle(int ms) {
    final engine = _engine;
    if (engine == null) return;
    if (!engine.supportsSubtitleDelay) {
      showToast('当前播放内核不支持调整字幕延迟');
      return;
    }
    _subDelay += Duration(milliseconds: ms);
    engine.setSubtitleDelay(_subDelay);
    final s = _subDelay.inMilliseconds / 1000;
    showToast(s == 0 ? '字幕延迟：0' : '字幕${s > 0 ? '推后' : '提前'} ${s.abs().toStringAsFixed(1)} 秒');
  }

  VideoFit _fit = VideoFit.contain;

  void _setFit(VideoFit fit) {
    _fit = fit;
    _engine?.setVideoFit(fit);
    showToast('画面比例：${fit.label}');
  }

  void _setSubtitleScale(double scale) {
    _engine?.setSubtitleScale(scale);
    ref.read(configProvider.notifier).update((c) => c.copyWith(playback: c.playback.copyWith(subtitleScale: scale)));
  }

  // ───────────────────────── 滑块调整（Windows）─────────────────────────

  /// 正在用滑块调整的一项（字幕位置 / 字幕延迟 / 弹幕时间）；null = 没在调整。调整时控制层收起
  _Adjusting? _adjusting;

  /// 调整中、还没保存的值（返回键完成时用）
  double? _adjustValue;

  /// 关掉所有菜单（包括上一级的「播放设置」），打开滑块面板
  void _startAdjust(_Adjusting what) {
    Navigator.of(context).popUntil((r) => r is! PopupRoute);
    _osdTimer?.cancel();
    setState(() {
      _adjusting = what;
      _adjustValue = null;
      _panel = OsdPanel.none;
      _osd = false;
    });
  }

  double get _adjustInitial => switch (_adjusting) {
    _Adjusting.subtitlePosition => SubtitleLift.fromPosition(
      ref.read(configProvider).playback.subtitlePosition,
    ).toDouble(),
    _Adjusting.subtitleDelay => _subDelay.inMilliseconds / 1000,
    _Adjusting.danmakuShift => _danmakuChoice.shiftMs / 1000,
    _Adjusting.audioDelay => _audioDelayMs / 1000,
    null => 0,
  };

  /// 拖动中：实时作用到画面上（字幕位置、字幕延迟直接改内核；弹幕偏移直接改显示）
  void _previewAdjust(double v) {
    _adjustValue = v;
    switch (_adjusting) {
      case _Adjusting.subtitlePosition:
        _engine?.setSubtitlePosition(SubtitleLift.toPosition(v.round()));
      case _Adjusting.subtitleDelay:
        _subDelay = Duration(milliseconds: (v * 1000).round());
        _engine?.setSubtitleDelay(_subDelay);
      case _Adjusting.danmakuShift:
        setState(() => _danmakuChoice = _danmakuChoice.copyWith(shiftMs: (v * 1000).round()));
      case _Adjusting.audioDelay:
        _engine?.setAudioDelay(Duration(milliseconds: (v * 1000).round()));
      case null:
    }
  }

  /// 调整完成：保存，焦点回到播放器
  void _finishAdjust(double v) {
    final what = _adjusting;
    _previewAdjust(v);
    _adjustValue = null;
    setState(() => _adjusting = null);
    _focus.requestFocus();
    switch (what) {
      case _Adjusting.subtitlePosition:
        final position = SubtitleLift.toPosition(v.round());
        ref
            .read(configProvider.notifier)
            .update((c) => c.copyWith(playback: c.playback.copyWith(subtitlePosition: position)));
      case _Adjusting.danmakuShift:
        final target = _danmakuTarget;
        if (target != null) unawaited(DanmakuChoiceStore.set(target.key, _danmakuChoice));
      case _Adjusting.audioDelay:
        _setAudioDelay((v * 1000).round(), toast: false);
      case _Adjusting.subtitleDelay || null:
    }
  }

  /// 电视：字幕上下微调（菜单里每次 5%）。delta 为正往上移，null = 恢复默认
  void _moveSubtitle(int? delta) {
    final current = ref.read(configProvider).playback.subtitlePosition;
    final position = delta == null ? 100 : SubtitleLift.toPosition(SubtitleLift.fromPosition(current) + delta);
    _engine?.setSubtitlePosition(position);
    ref
        .read(configProvider.notifier)
        .update((c) => c.copyWith(playback: c.playback.copyWith(subtitlePosition: position)));
    showToast('字幕位置：${SubtitleLift.label(position)}');
  }

  /// 起播 / 换源后把当前的显示设置交给内核（换源会新开媒体，内核可能是新的）
  Future<void> _applyDisplay(PlayerEngine engine) async {
    if (_fit != VideoFit.contain) await engine.setVideoFit(_fit);
    final scale = ref.read(configProvider).playback.subtitleScale;
    if (scale != 1) await engine.setSubtitleScale(scale);
    final position = ref.read(configProvider).playback.subtitlePosition;
    if (position != 100 && engine.supportsSubtitlePosition) await engine.setSubtitlePosition(position);
    if (_subDelay != Duration.zero) await engine.setSubtitleDelay(_subDelay);
    _appliedHdr = null;
    _applySubtitleBrightness(engine);
    final look = ref.read(configProvider).playback.subtitleLook;
    if (!look.isDefault) await engine.setSubtitleLook(look);
    final audioDelay = ref.read(configProvider).playback.audioDelayMs;
    if (audioDelay != 0 && engine.supportsAudioDelay) await engine.setAudioDelay(Duration(milliseconds: audioDelay));
  }

  // ───────────────────────── 上一集 ─────────────────────────

  Future<void> _playPrevious() async {
    final item = _item, client = _client;
    if (item == null || client == null || item.kind != MediaKind.episode || item.seriesId == null) return;
    try {
      final prev = previousEpisodeBefore(await _loadEpisodes(client, item.seriesId!), item);
      if (!mounted) return;
      if (prev == null) {
        showToast('已经是第一集');
        return;
      }
      _handoffTo('/play/${widget.serverId}/${prev.id}?pos=0&resume=1');
    } catch (e) {
      if (mounted) showToast('获取集列表失败');
    }
  }

  /// 进度条点击 / 拖动（Windows）
  void _seekTo(Duration to) {
    _expectStart = null;
    _seekTimer?.cancel();
    _lastPosition = to;
    setState(() => _pendingSeek = null);
    _engine?.seek(to);
    _showOsd();
    _report();
  }

  void _togglePlay() {
    _engine?.playOrPause();
    _showOsd();
  }

  void _closePanel() {
    setState(() => _panel = OsdPanel.none);
    _armOsdTimer();
    if (PlatformProfile.isTv) _focusControls();
  }

  /// 返回键，返回 true 表示已处理（不退出播放）。
  /// - 电视：面板、按钮、控制层哪个开着都先回到默认的播放画面（关面板、隐藏控制层、焦点回到画面），
  ///   默认画面上再按才退出
  /// - Windows：关面板 → 关媒体信息 → 退出小窗 / 全屏 → 隐藏控制层 → 退出播放
  ///
  /// 遥控器返回键在安卓上走系统返回（不经过按键事件），所以通过 [BackHandler] 挂到应用的返回链上；
  /// 键盘 Esc 等由 [_onKey] 调这里
  bool _handleBack() {
    if (!mounted) return false;
    if (_adjusting != null) {
      _finishAdjust(_adjustValue ?? _adjustInitial);
      return true;
    }
    if (_nextCountdown != null) {
      _cancelNextCountdown();
      return true;
    }
    final tv = PlatformProfile.isTv;
    if (_panel != OsdPanel.none || (tv && (_onControls || _osd))) {
      _osdTimer?.cancel();
      setState(() {
        _panel = OsdPanel.none;
        _osd = false;
      });
      _focus.requestFocus();
      return true;
    }
    if (_info) {
      setState(() => _info = false);
      return true;
    }
    if (PlatformProfile.isDesktop) {
      if (MiniPlayerWindow.active.value) {
        unawaited(MiniPlayerWindow.exit());
        return true;
      }
      if (windowFullScreen.value) {
        unawaited(toggleFullScreen());
        return true;
      }
    }
    if (_osd && _state.playing) {
      setState(() => _osd = false);
      return true;
    }
    return false;
  }

  static bool _isBack(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.goBack ||
      key == LogicalKeyboardKey.escape ||
      key == LogicalKeyboardKey.gameButtonB ||
      key == LogicalKeyboardKey.backspace;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final repeat = event is KeyRepeatEvent;

    if (_isBack(key)) {
      // 松开也消费掉：不然安卓会把没被处理的松开再转成一次系统返回，一次按键退两步
      if (event is KeyDownEvent) {
        BackDedup.markKey();
        if (!_handleBack() && mounted) context.pop();
      }
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    _autoPlayStreak = 0;
    if (_onControls) {
      if (PlatformProfile.isTv) {
        // 电视：焦点在按钮 / 面板上时，方向键移动焦点、OK 点击，交给按钮处理
        _showOsd();
        return KeyEventResult.ignored;
      }
      // Windows：鼠标悬停让按钮拿到了焦点，回车照常点击按钮，其他快捷键仍然作用于播放器
      if (confirmKeys.contains(key)) return KeyEventResult.ignored;
      // 滑块调整面板打开时，空格等快捷键照常生效，但焦点留在面板上，方向键继续调滑块
      if (_adjusting == null) _focus.requestFocus();
    }

    final step = Duration(seconds: ref.read(configProvider).playback.seekStepSeconds);
    final desktop = PlatformProfile.isDesktop;
    final keyboard = HardwareKeyboard.instance;
    final digit = _digitOf(key);

    // 片尾「下一集」倒计时：OK / 回车立即播放下一集
    if (_nextCountdown != null && confirmKeys.contains(key) && !repeat) {
      _playNextNow();
      return KeyEventResult.handled;
    }
    if (desktop &&
        keyboard.isControlPressed &&
        (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight)) {
      // Windows：Ctrl + ←→ 字幕提前 / 推后 0.1 秒
      _shiftSubtitle(key == LogicalKeyboardKey.arrowLeft ? -100 : 100);
    } else if (desktop &&
        keyboard.isShiftPressed &&
        (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight)) {
      // Windows：Shift + ←→ ±60 秒
      _seekBy(Duration(seconds: key == LogicalKeyboardKey.arrowLeft ? -60 : 60));
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.keyJ) {
      _seekBy(-_holdDelta(step, repeat));
    } else if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.keyL) {
      _seekBy(_holdDelta(step, repeat));
    } else if (digit != null && !repeat && (desktop || digit > 0)) {
      // 数字键跳到 N0% 处（电视 1–9，Windows 0–9）
      final d = _state.duration;
      if (d > Duration.zero) _seekBy(d * (digit / 10) - (_pendingSeek ?? _state.position));
    } else if (desktop && !repeat && key == LogicalKeyboardKey.bracketLeft) {
      _stepRate(-1);
    } else if (desktop && !repeat && key == LogicalKeyboardKey.bracketRight) {
      _stepRate(1);
    } else if (desktop && !repeat && key == LogicalKeyboardKey.backslash) {
      _setRate(1);
    } else if (desktop && !repeat && key == LogicalKeyboardKey.keyS && _skipPrompt != null) {
      _activateSkip();
    } else if (!repeat &&
        (key == LogicalKeyboardKey.mediaTrackPrevious ||
            key == LogicalKeyboardKey.channelDown ||
            (desktop && key == LogicalKeyboardKey.keyN && keyboard.isShiftPressed))) {
      // 上一集：上一曲键 / 频道 -；Windows Shift + N
      _playPrevious();
    } else if (!repeat && key == LogicalKeyboardKey.channelUp) {
      _playNext();
    } else if (repeat && PlatformProfile.isDesktop && key == LogicalKeyboardKey.arrowUp) {
      _setVolume(_volume + 0.05, repeat: true);
    } else if (repeat && PlatformProfile.isDesktop && key == LogicalKeyboardKey.arrowDown) {
      _setVolume(_volume - 0.05);
    } else if (repeat) {
      return KeyEventResult.handled;
    } else if (confirmKeys.contains(key) && _skipVisible) {
      // 出现"跳过片头 / 下一集"按钮时，OK 键执行跳过（空格仍是暂停）
      _activateSkip();
    } else if (confirmKeys.contains(key) ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.keyK ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlay();
    } else if (key == LogicalKeyboardKey.mediaPlay) {
      _engine?.play();
    } else if (key == LogicalKeyboardKey.mediaPause) {
      _engine?.pause();
    } else if (key == LogicalKeyboardKey.arrowUp && PlatformProfile.isDesktop) {
      // Windows：↑↓ 音量 ±5%（docs/07 §3.5；播放设置在右键 / 菜单键 / 「更多」）
      _setVolume(_volume + 0.05);
    } else if (key == LogicalKeyboardKey.arrowDown && PlatformProfile.isDesktop) {
      _setVolume(_volume - 0.05);
    } else if (key == LogicalKeyboardKey.keyM && PlatformProfile.isDesktop) {
      _toggleMute();
    } else if (key == LogicalKeyboardKey.arrowUp) {
      // 电视：↑ 直接到右上角的按钮（弹幕、音轨、字幕、更多）
      _focusTop();
    } else if (key == LogicalKeyboardKey.arrowDown) {
      // 电视：焦点移到底部按钮行
      _focusControls();
    } else if (key == LogicalKeyboardKey.contextMenu || key == LogicalKeyboardKey.gameButtonX) {
      _openMenu();
    } else if (key == LogicalKeyboardKey.keyI || key == LogicalKeyboardKey.info) {
      setState(() => _info = !_info);
    } else if (key == LogicalKeyboardKey.keyN || key == LogicalKeyboardKey.mediaTrackNext) {
      _playNext();
    } else if (key == LogicalKeyboardKey.keyD && PlatformProfile.isDesktop) {
      // Windows：D 键开关弹幕（电视在控制层 / 菜单里操作）
      _toggleDanmaku();
    } else if (key == LogicalKeyboardKey.keyF && PlatformProfile.isDesktop) {
      toggleFullScreen();
    } else if (key == LogicalKeyboardKey.keyP && PlatformProfile.isDesktop) {
      MiniPlayerWindow.toggle();
    } else if (key == LogicalKeyboardKey.keyA) {
      _cycleAudio();
    } else if (key == LogicalKeyboardKey.keyC) {
      _cycleSubtitle();
    } else if (key == LogicalKeyboardKey.mediaStop) {
      context.pop();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _playNext() async {
    final next = await _resolveNextEpisode();
    if (!mounted) return;
    if (next == null) {
      if (_item?.kind == MediaKind.episode) showToast('已经是最后一集');
      return;
    }
    _handoffTo('/play/${widget.serverId}/${next.id}?pos=0&resume=1');
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

  /// 弹出菜单期间控制层保持显示，关闭后焦点回到原来的位置
  Future<void> _menu(Future<void> Function() show) async {
    final restore = FocusManager.instance.primaryFocus;
    _showOsd(sticky: true);
    await show();
    // 菜单里选了滑块调整：焦点交给滑块面板，不还给原来的按钮
    if (!mounted || _adjusting != null) return;
    // Windows 用鼠标操作、菜单关闭时鼠标已不在控制栏上：焦点回到画面，按钮不保持高亮
    final pointerAway = PlatformProfile.isDesktop && InputMode.pointer && !_hoverControls;
    (!pointerAway && restore != null && restore.context != null && restore.context!.mounted ? restore : _focus)
        .requestFocus();
    _armOsdTimer();
  }

  /// Windows：鼠标移出控制栏时，鼠标悬停时拿到焦点的按钮交还焦点（不然按钮一直白色高亮，像是选中了）。
  /// 键盘操作（方向键移动焦点）时不动；打开着面板时也不动
  void _onHoverControls(bool inside) {
    _hoverControls = inside;
    if (inside || !PlatformProfile.isDesktop || !InputMode.pointer || _panel != OsdPanel.none) return;
    if (_onControls && ModalRoute.of(context)?.isCurrent == true) _focus.requestFocus();
  }

  Future<void> _openDanmakuSettings() => _menu(_openDanmakuMenu);

  Future<void> _openAudioMenu() => _menu(() {
    if (_state.audioTracks.isEmpty) {
      showToast('没有可选的音轨');
      return Future.value();
    }
    return showContextMenu(context, anchored: true, title: '音轨', actionsBuilder: _audioItems);
  });

  List<MenuAction> _audioItems() {
    final s = _state;
    final delay = _audioDelayMs;
    final label = SliderSpec.audioDelayLabel(delay / 1000);
    return [
      for (final t in s.audioTracks)
        MenuAction(
          '${t.displayName}${t == s.audio ? '  ✓' : ''}',
          Icons.graphic_eq_rounded,
          () => _engine?.selectAudio(t),
        ),
      // 音画同步：Windows 打开滑块；电视是菜单，按档调整
      if ((_engine?.supportsAudioDelay ?? false) && PlatformProfile.isDesktop)
        MenuAction('音画同步 · $label', Icons.sync_rounded, () => _startAdjust(_Adjusting.audioDelay))
      else if (_engine?.supportsAudioDelay ?? false)
        MenuAction.submenu(
          '音画同步 · $label',
          Icons.sync_rounded,
          title: '音画同步（声音比画面慢就选「提前」）',
          items: () => [
            for (final ms in const [-500, -250, -100, -50, 50, 100, 250, 500])
              MenuAction(
                '声音${ms > 0 ? '推后' : '提前'} ${ms.abs()} 毫秒',
                Icons.sync_rounded,
                () => _setAudioDelay(_audioDelayMs + ms),
              ),
            MenuAction('恢复为 0', Icons.restart_alt_rounded, () => _setAudioDelay(0)),
          ],
        ),
    ];
  }

  static String _subtitleLookLabel(SubtitleLook look) {
    if (look.isDefault) return '默认';
    String of<T>(List<(T, String)> options, T v) => options.where((o) => o.$1 == v).firstOrNull?.$2 ?? '';
    return [
      if (look.color != SubtitleLook.white) of(SubtitleLook.colors, look.color),
      if (look.edge != SubtitleEdge.auto) of(SubtitleLook.edges, look.edge),
      if (look.outline != 1.0 && look.edge != SubtitleEdge.box) of(SubtitleLook.outlines, look.outline),
    ].join(' · ');
  }

  Future<void> _openSubtitleMenu() =>
      _menu(() => showContextMenu(context, anchored: true, title: '字幕', actionsBuilder: _subtitleItems));

  List<MenuAction> _subtitleItems() {
    final s = _state;
    final external = _source?.subtitles.where((x) => x.isExternal).toList() ?? const <MediaStreamInfo>[];
    final scale = ref.read(configProvider).playback.subtitleScale;
    final position = ref.read(configProvider).playback.subtitlePosition;
    return [
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
      if ((_engine?.supportsSecondarySubtitle ?? false) && s.subtitleTracks.length > 1)
        MenuAction.submenu(
          '第二字幕 · ${_engine?.secondarySubtitle?.displayName ?? '关'}',
          Icons.subtitles_rounded,
          title: '第二字幕（双语：显示在主字幕下方；只支持文字字幕）',
          items: () {
            final current = _engine?.secondarySubtitle;
            return [
              MenuAction(
                '关闭${current == null ? '  ✓' : ''}',
                Icons.subtitles_off_rounded,
                () => _engine?.selectSecondarySubtitle(null),
              ),
              for (final t in _state.subtitleTracks)
                if (t.isTextSubtitle && t != _state.subtitle)
                  MenuAction(
                    '${t.displayName}${t == current ? '  ✓' : ''}',
                    Icons.subtitles_rounded,
                    () => _engine?.selectSecondarySubtitle(t),
                  ),
            ];
          },
        ),
      for (final x in external)
        MenuAction('外挂 · ${x.displayName}', Icons.closed_caption_outlined, () async {
          try {
            final url = await _client?.subtitleUri(_source!, x);
            if (url != null) await _engine?.addExternalSubtitle(url, title: x.displayName, language: x.language);
          } catch (e) {
            showToast('加载字幕失败：$e');
          }
        }),
      MenuAction.submenu(
        '在线搜索字幕',
        Icons.travel_explore_rounded,
        title: '在线搜索字幕',
        items: () => [
          MenuAction('中文字幕', Icons.translate_rounded, () => _searchSubtitles('chi', '中文')),
          MenuAction('英文字幕', Icons.translate_rounded, () => _searchSubtitles('eng', '英文')),
        ],
      ),
      MenuAction.submenu(
        '字幕大小 · ${DanmakuConfig.labelOf(PlaybackConfig.subtitleScales, scale)}',
        Icons.format_size_rounded,
        title: '字幕大小',
        items: () => [
          for (final (v, label) in PlaybackConfig.subtitleScales)
            MenuAction('$label${v == scale ? '  ✓' : ''}', Icons.format_size_rounded, () => _setSubtitleScale(v)),
        ],
      ),
      MenuAction.submenu(
        '字幕样式 · ${_subtitleLookLabel(ref.read(configProvider).playback.subtitleLook)}',
        Icons.text_format_rounded,
        title: '字幕样式（ASS 等自带样式的字幕在电视上按字幕自己的样式）',
        items: () {
          final look = ref.read(configProvider).playback.subtitleLook;
          String mark(bool on) => on ? '  ✓' : '';
          return [
            for (final (v, label) in SubtitleLook.colors)
              MenuAction(
                '颜色 · $label${mark(v == look.color)}',
                Icons.format_color_text_rounded,
                () => _setSubtitleLook(SubtitleLook(color: v, edge: look.edge, outline: look.outline)),
              ),
            for (final (v, label) in SubtitleLook.edges)
              MenuAction(
                '边框 · $label${mark(v == look.edge)}',
                Icons.border_style_rounded,
                () => _setSubtitleLook(SubtitleLook(color: look.color, edge: v, outline: look.outline)),
              ),
            if (look.edge != SubtitleEdge.box)
              for (final (v, label) in SubtitleLook.outlines)
                MenuAction(
                  '${look.edge == SubtitleEdge.shadow ? '阴影' : '描边'}粗细 · $label${mark(v == look.outline)}',
                  Icons.line_weight_rounded,
                  () => _setSubtitleLook(SubtitleLook(color: look.color, edge: look.edge, outline: v)),
                ),
          ];
        },
      ),
      MenuAction.submenu(
        'HDR 字幕亮度 · ${DanmakuConfig.labelOf(PlaybackConfig.hdrSubtitleBrightnesses, ref.read(configProvider).playback.hdrSubtitleBrightness)}',
        Icons.brightness_6_rounded,
        title: 'HDR 字幕亮度（只对 HDR / 杜比视界片源生效）',
        items: () {
          final current = ref.read(configProvider).playback.hdrSubtitleBrightness;
          return [
            for (final (v, label) in PlaybackConfig.hdrSubtitleBrightnesses)
              MenuAction(
                '$label${v == current ? '  ✓' : ''}',
                Icons.brightness_6_rounded,
                () => _setHdrSubtitleBrightness(v),
              ),
          ];
        },
      ),
      // Windows：打开滑块精确调整；电视：仍是菜单，每次 5%
      if ((_engine?.supportsSubtitlePosition ?? false) && PlatformProfile.isDesktop)
        MenuAction(
          '字幕位置 · ${SubtitleLift.label(position)}',
          Icons.vertical_align_center_rounded,
          () => _startAdjust(_Adjusting.subtitlePosition),
        )
      else if (_engine?.supportsSubtitlePosition ?? false)
        MenuAction.submenu(
          '字幕位置 · ${SubtitleLift.label(position)}',
          Icons.vertical_align_center_rounded,
          title: '字幕位置',
          items: () => [
            MenuAction('上移 5%', Icons.arrow_upward_rounded, () => _moveSubtitle(5)),
            MenuAction('下移 5%', Icons.arrow_downward_rounded, () => _moveSubtitle(-5)),
            MenuAction('恢复默认', Icons.restart_alt_rounded, () => _moveSubtitle(null)),
          ],
        ),
      if ((_engine?.supportsSubtitleDelay ?? false) && PlatformProfile.isDesktop)
        MenuAction(
          '字幕延迟 · ${SliderSpec.subtitleDelay.format(_subDelay.inMilliseconds / 1000)}',
          Icons.schedule_rounded,
          () => _startAdjust(_Adjusting.subtitleDelay),
        )
      else if (_engine?.supportsSubtitleDelay ?? false)
        MenuAction.submenu(
          '字幕延迟 · ${_subDelay == Duration.zero ? '无' : '${_subDelay.isNegative ? '' : '+'}${(_subDelay.inMilliseconds / 1000).toStringAsFixed(1)} 秒'}',
          Icons.schedule_rounded,
          title: '字幕延迟（正数 = 字幕推后）',
          items: () => [
            for (final ms in const [-2000, -1000, -500, -100, 100, 500, 1000, 2000])
              MenuAction(
                '${ms > 0 ? '推后' : '提前'} ${(ms.abs() / 1000).toStringAsFixed(1)} 秒',
                Icons.schedule_rounded,
                () => _shiftSubtitle(ms),
              ),
            MenuAction('恢复为 0', Icons.restart_alt_rounded, () => _shiftSubtitle(-_subDelay.inMilliseconds)),
          ],
        ),
    ];
  }

  // ───────────────────────── 在线字幕 ─────────────────────────

  /// 在线找字幕要用的片名、年份和 ID（剧集用剧的 TMDB / IMDb ID）
  Future<SubtitleQuery?> _subtitleQuery() async {
    final item = _item, client = _client;
    if (item == null || client == null) return null;
    final episode = item.kind == MediaKind.episode;
    MediaItem? title = item;
    if (episode) {
      // 剧集要用整部剧的 ID 和原名；取不到剧的信息时只按剧名搜，不能拿单集的 ID 当剧的 ID
      title = null;
      if (item.seriesId != null) {
        try {
          title = await client.item(item.seriesId!);
        } catch (_) {}
      }
    }
    return SubtitleQuery(
      title: episode ? (item.seriesName ?? title?.name ?? item.name) : item.name,
      originalTitle: title?.originalTitle,
      year: title?.year,
      tmdbId: int.tryParse(title?.tmdbId ?? ''),
      imdbId: title?.imdbId,
      season: episode ? item.seasonNumber : null,
      episode: episode ? item.episodeNumber : null,
    );
  }

  /// 同时在媒体服务器（字幕插件）和内置的在线字幕来源里搜索，合并列出
  Future<void> _searchSubtitles(String language, String label) async {
    final client = _client, item = _item;
    if (client == null || item == null) return;
    final lang = SubtitleLanguage.values.firstWhere((l) => l.code == language);
    final providers = onlineSubtitleProviders(ref.read(configProvider).subtitles);
    showToast('正在搜索$label字幕…');
    final errors = <String>[];
    var serverDenied = false;
    final query = await _subtitleQuery();
    final results = await Future.wait<List<MenuAction>>([
      client
          .searchSubtitles(item.id, language)
          .then(
            (list) => [
              for (final r in list.take(30))
                MenuAction(
                  [
                    r.name,
                    r.provider.isEmpty ? '服务器' : '服务器 · ${r.provider}',
                    ?r.format?.toUpperCase(),
                    if (r.downloads != null) '${r.downloads} 次下载',
                  ].where((x) => x.isNotEmpty).join(' · '),
                  Icons.closed_caption_outlined,
                  () => _downloadSubtitle(r),
                ),
            ],
            onError: (Object e) {
              // 服务器没装字幕插件或账号没权限：只要内置来源有结果就不打扰
              serverDenied = e is MediaServerException && (e.statusCode == 401 || e.statusCode == 403);
              if (providers.isEmpty) errors.add(serverDenied ? '当前账号没有字幕管理权限' : '服务器：$e');
              return const <MenuAction>[];
            },
          ),
      for (final p in providers)
        if (query != null)
          p
              .search(query, lang)
              .then(
                (list) => [
                  for (final r in list.take(30))
                    MenuAction(
                      [
                        r.name,
                        r.provider,
                        ?r.language,
                        ?r.format?.toUpperCase(),
                        if (r.downloads != null) '${r.downloads} 次下载',
                      ].where((x) => x.isNotEmpty).join(' · '),
                      Icons.closed_caption_outlined,
                      () => _loadOnlineSubtitle(p, r),
                    ),
                ],
                onError: (Object e) {
                  errors.add('$e');
                  return const <MenuAction>[];
                },
              ),
    ]);
    if (!mounted) return;
    final actions = [for (final r in results) ...r];
    if (actions.isEmpty) {
      showToast(
        errors.isNotEmpty
            ? '搜索字幕失败：${errors.join('；')}'
            : serverDenied
            ? '当前账号没有字幕管理权限：请在服务器的用户设置里允许管理字幕'
            : providers.isEmpty
            ? '没有找到$label字幕（服务器需要安装 OpenSubtitles 等字幕插件，或在设置 → 接口与网络 → 在线字幕里填写射手网（伪）token）'
            : '没有找到$label字幕',
      );
      return;
    }
    if (errors.isNotEmpty) showToast(errors.join('；'));
    await _menu(
      () => showContextMenu(context, anchored: true, title: '$label字幕 · ${actions.length} 个结果', actions: actions),
    );
  }

  /// 内置来源的字幕：下载到本机临时目录，直接加载到播放器（不经过媒体服务器）
  Future<void> _loadOnlineSubtitle(OnlineSubtitleProvider provider, OnlineSubtitle r) async {
    showToast('正在下载字幕…');
    try {
      final file = await provider.download(r);
      final path = await saveSubtitleFile(file);
      if (!mounted) return;
      await _engine?.addExternalSubtitle(Uri.file(path), title: '${r.provider} · ${r.name}');
      showToast('已加载字幕：${r.name}');
    } catch (e) {
      showToast('下载字幕失败：$e');
    }
  }

  Future<void> _downloadSubtitle(RemoteSubtitle r) async {
    final client = _client, item = _item, source = _source;
    if (client == null || item == null || source == null) return;
    showToast('正在下载字幕…');
    final before = {for (final x in source.subtitles) x.index};
    try {
      await client.downloadSubtitle(item.id, r.id);
      // 服务器保存字幕后才会出现在播放信息里：最多等几秒
      MediaSourceInfo? updated;
      List<MediaStreamInfo> added = const [];
      for (var i = 0; i < 5 && added.isEmpty; i++) {
        if (i > 0) await Future<void>.delayed(const Duration(seconds: 1));
        final info = await client.playbackInfo(item.id, isPlayback: false);
        updated = info.sources.where((x) => x.id == source.id).firstOrNull;
        added = updated?.subtitles.where((x) => x.isExternal && !before.contains(x.index)).toList() ?? const [];
      }
      if (!mounted) return;
      if (updated == null || added.isEmpty) {
        showToast('字幕已下载到服务器，重新打开播放后可在字幕菜单里选择');
        return;
      }
      setState(() => _source = updated);
      final x = added.last;
      final url = await client.subtitleUri(updated, x);
      if (url == null || !mounted) return;
      await _engine?.addExternalSubtitle(url, title: x.displayName, language: x.language);
      showToast('已加载字幕：${x.displayName}');
    } catch (e) {
      showToast('下载字幕失败：$e');
    }
  }

  /// 手动标记片头 / 片尾：以当前播放位置为准，剧集同一季各集通用
  String _markTitle(SegmentQuery query) =>
      '片头片尾标记（${query.kind == SegmentMediaKind.episode ? '第 ${query.season ?? 0} 季各集通用' : '这部电影'}）';

  List<MenuAction> _markItems() {
    final query = _segmentQuery;
    if (query == null) return const [];
    final pos = _state.position;
    final duration = query.duration;
    final m = _manualMark;
    String clock(Duration d) => formatClock(d);
    // 现在实际生效的片段（手动标记优先，否则来自媒体服务器 / 片头片尾数据库），写在每一项下面的灰字里
    String from(Segment x) => x.provider == 'manual' ? '手动标记' : '来自${segmentProviderName(x.provider)}';
    final intro = _segmentList.where((x) => x.type == SegmentType.intro).firstOrNull;
    final credits = _segmentList.where((x) => x.type == SegmentType.credits).firstOrNull;
    final introNow = intro == null ? '现在：没有片头' : '现在：片头 ${clock(intro.start)}–${clock(intro.end)}（${from(intro)}）';
    final creditsNow = credits == null
        ? '现在：没有片尾'
        : '现在：片尾从 ${clock(credits.start)} 开始，结尾前 ${clock(duration - credits.start)}（${from(credits)}）';
    return [
      MenuAction('片头到这里结束（${clock(pos)}）', Icons.first_page_rounded, detail: introNow, () {
        if (pos <= (m.introStart ?? Duration.zero)) {
          showToast('片头结束要在片头开始之后');
          return;
        }
        _saveMark(m.copyWith(introEnd: pos), '片头 ${clock(m.introStart ?? Duration.zero)}–${clock(pos)}');
      }),
      MenuAction(
        '片头从这里开始（${clock(pos)}）',
        Icons.start_rounded,
        detail: m.introStart == null ? '手动标记的片头默认从 00:00 开始' : '手动标记的片头现在从 ${clock(m.introStart!)} 开始',
        () {
          // 有些剧先放一段正片再进片头：片头开始后移；已有的结束点在它之前就作废
          final end = m.introEnd;
          final next = end != null && end <= pos
              ? ManualMark(introStart: pos, creditsFromEnd: m.creditsFromEnd)
              : m.copyWith(introStart: pos);
          _saveMark(next, '片头从 ${clock(pos)} 开始${next.introEnd == null ? '，请再标记片头结束' : ''}');
        },
      ),
      MenuAction('片尾从这里开始（${clock(pos)}）', Icons.last_page_rounded, detail: creditsNow, () {
        if (pos >= duration || (m.introEnd != null && pos <= m.introEnd!)) {
          showToast('片尾开始要在片头之后、结尾之前');
          return;
        }
        _saveMark(m.copyWith(creditsFromEnd: duration - pos), '片尾从结尾前 ${clock(duration - pos)} 开始');
      }),
      if (m.introEnd != null || m.introStart != null)
        MenuAction(
          '清除片头标记',
          Icons.backspace_outlined,
          () => _saveMark(m.copyWith(clearIntro: true), '已清除片头标记'),
          detail: '手动标记：${clock(m.introStart ?? Duration.zero)}–${m.introEnd == null ? '未标结束' : clock(m.introEnd!)}',
        ),
      // 片头片尾时长固定的剧（多数国产剧）：直接选秒数，不用播放到那个位置再标
      MenuAction.submenu(
        '片头固定为开头 N 秒',
        Icons.first_page_rounded,
        detail: m.introEnd == null || (m.introStart ?? Duration.zero) > Duration.zero
            ? '不用播放到那里，直接选秒数'
            : '现在：开头 ${m.introEnd!.inSeconds} 秒',
        title: '片头固定为开头多少秒',
        items: () => [
          for (final sec in const [30, 45, 60, 75, 90, 105, 120, 150, 180])
            MenuAction(
              '$sec 秒（跳到 ${clock(Duration(seconds: sec))}）${m.introEnd == Duration(seconds: sec) && (m.introStart ?? Duration.zero) == Duration.zero ? '  ✓' : ''}',
              Icons.timer_outlined,
              () => _saveMark(
                ManualMark(
                  introEnd: Duration(seconds: sec),
                  creditsFromEnd: _manualMark.creditsFromEnd,
                ),
                '片头 00:00–${clock(Duration(seconds: sec))}',
              ),
            ),
        ],
      ),
      MenuAction.submenu(
        '片尾固定为结尾 N 秒',
        Icons.last_page_rounded,
        detail: m.creditsFromEnd == null ? '不用播放到那里，直接选秒数' : '现在：结尾 ${m.creditsFromEnd!.inSeconds} 秒',
        title: '片尾固定为结尾多少秒',
        items: () => [
          for (final sec in const [30, 60, 90, 120, 150, 180, 240, 300])
            MenuAction(
              '$sec 秒${m.creditsFromEnd == Duration(seconds: sec) ? '  ✓' : ''}',
              Icons.timer_outlined,
              () => _saveMark(
                _manualMark.copyWith(creditsFromEnd: Duration(seconds: sec)),
                '片尾从结尾前 ${clock(Duration(seconds: sec))} 开始',
              ),
            ),
        ],
      ),
      if (m.creditsFromEnd != null)
        MenuAction(
          '清除片尾标记',
          Icons.backspace_outlined,
          () => _saveMark(m.copyWith(clearCredits: true), '已清除片尾标记'),
          detail: '手动标记：结尾前 ${clock(m.creditsFromEnd!)}',
        ),
    ];
  }

  Future<void> _saveMark(ManualMark mark, String what) async {
    final query = _segmentQuery;
    if (query == null) return;
    setState(() => _manualMark = mark);
    _segments?.setManual(mark.segmentsFor(query.duration));
    try {
      await ManualSegmentStore.save(query, mark);
      final scope = query.kind == SegmentMediaKind.episode ? '，本季其他集自动沿用' : '';
      showToast(what.startsWith('已') ? what : '已标记：$what$scope');
    } catch (e) {
      showToast('保存标记失败：$e');
    }
  }

  Future<void> _openRateMenu() =>
      _menu(() => showContextMenu(context, anchored: true, title: '倍速', actionsBuilder: _rateItems));

  List<MenuAction> _rateItems() {
    final rate = _state.rate;
    return [
      for (final r in _rates)
        MenuAction('${r}x${rate == r ? '  ✓' : ''}', Icons.speed_rounded, () => _engine?.setRate(r)),
    ];
  }

  /// 「更多」：完整的播放设置菜单
  Future<void> _openMenu() => _menu(() {
    return showContextMenu(context, anchored: true, title: '播放设置', actionsBuilder: _moreItems);
  });

  List<MenuAction> _moreItems() {
    final s = _state;
    final engine = _engine;
    final query = _segmentQuery;
    return [
      if (s.audioTracks.isEmpty)
        MenuAction('音轨 · 0 条', Icons.audiotrack_rounded, _openAudioMenu)
      else
        MenuAction.submenu('音轨 · ${s.audioTracks.length} 条', Icons.audiotrack_rounded, title: '音轨', items: _audioItems),
      MenuAction.submenu(
        '字幕 · ${s.subtitleTracks.length} 条',
        Icons.subtitles_rounded,
        title: '字幕',
        items: _subtitleItems,
      ),
      if (_danmakuClient == null)
        MenuAction('弹幕 · $_danmakuStatus', Icons.chat_outlined, _openDanmakuMenu)
      else
        MenuAction.submenu('弹幕 · $_danmakuStatus', Icons.chat_outlined, title: _danmakuTitle, items: _danmakuItems),
      MenuAction('切换资源（所有服务器）', Icons.swap_horiz_rounded, () => _openPanel(OsdPanel.sources)),
      if (_item?.kind == MediaKind.episode)
        MenuAction('选集', Icons.video_library_outlined, () => _openPanel(OsdPanel.episodes)),
      MenuAction.submenu('倍速 · ${s.rate}x', Icons.speed_rounded, title: '倍速', items: _rateItems),
      if (_chapters.length >= 2)
        MenuAction.submenu('章节 · ${_chapters.length} 个', Icons.bookmarks_outlined, title: '章节', items: _chapterItems),
      MenuAction.submenu('睡眠定时 · ${SleepTimer.label()}', Icons.bedtime_outlined, title: '睡眠定时', items: _sleepItems),
      MenuAction.submenu(
        '画面比例 · ${_fit.label}',
        Icons.aspect_ratio_rounded,
        title: '画面比例',
        items: () => [
          for (final f in VideoFit.values)
            MenuAction('${f.label}${f == _fit ? '  ✓' : ''}', Icons.aspect_ratio_rounded, () => _setFit(f)),
        ],
      ),
      if (_item?.kind == MediaKind.episode) MenuAction('上一集', Icons.skip_previous_rounded, _playPrevious),
      if (query != null)
        MenuAction.submenu(
          '片头片尾标记${_manualMark.isEmpty ? '' : ' · 已标记'}',
          Icons.bookmark_add_outlined,
          title: _markTitle(query),
          items: _markItems,
        ),
      if (ExoEngine.supported && engine != null)
        MenuAction(
          '播放内核 · ${engine.kind.label}（切换到 ${engine.kind == EngineKind.exo ? 'mpv' : 'ExoPlayer'}）',
          Icons.memory_rounded,
          () => _switchEngine(forceMpv: engine.kind == EngineKind.exo, forceExo: engine.kind == EngineKind.mpv),
        ),
      if (engine != null && engine.supportsDecoderSwitch)
        MenuAction(
          '解码方式 · ${ref.read(configProvider).playback.mpvHardwareDecoding ? '硬解' : '软解'}'
          '（切换到${ref.read(configProvider).playback.mpvHardwareDecoding ? '软解' : '硬解'}）',
          Icons.developer_board_rounded,
          _toggleHardwareDecoding,
        ),
      MenuAction('媒体信息', Icons.info_outline_rounded, () => setState(() => _info = true)),
    ];
  }

  /// 打开「播放资源」/「选集」面板（替换控制层底部的按钮行）
  void _openPanel(OsdPanel panel) {
    final item = _item;
    if (panel == OsdPanel.episodes) {
      final client = _client;
      if (item == null || client == null || item.seriesId == null) return;
      // 整部剧的所有季：面板里可以切换季
      _episodeList(client, item.seriesId!);
    }
    setState(() => _panel = panel);
    _showOsd(sticky: true);
  }

  /// 切换到另一个版本：同一台服务器同一条目直接换源，其他服务器的版本换到那台服务器从当前进度继续
  void _switchToOption(SourceOption o) {
    setState(() => _panel = OsdPanel.none);
    // 选中的卡片随面板一起消失：焦点回到画面，否则落空后暂停、快进都不响应
    _focus.requestFocus();
    _armOsdTimer();
    if (o.serverId == widget.serverId && o.source.id == _source?.id) return;
    final at = _state.position;
    if (o.serverId == widget.serverId && o.item.id == widget.itemId) {
      _reportStopped();
      _stopped = false;
      _started = false;
      _wasPlaying = false;
      _resetSegments();
      _start(sourceId: o.source.id, at: at);
      showToast('切换到 ${o.source.resolutionLabel} ${o.source.rangeLabel} · ${o.serverName}');
    } else {
      _handoffTo(o.playRoute(position: at));
    }
  }

  void _pickEpisode(MediaItem e) {
    setState(() => _panel = OsdPanel.none);
    if (e.id == widget.itemId) {
      _armOsdTimer();
      return;
    }
    _handoffTo('/play/${widget.serverId}/${e.id}?pos=${e.position.inMilliseconds}&resume=1');
  }

  // ───────────────────────── 界面 ─────────────────────────

  String get _title {
    final item = _item;
    if (item == null) return '';
    if (item.kind != MediaKind.episode) return item.year == null ? item.name : '${item.name} (${item.year})';
    final ep = [
      if (item.seasonNumber != null && item.seasonNumber! > 1) '第 ${item.seasonNumber} 季',
      if (item.episodeNumber != null) '第 ${item.episodeNumber} 集',
    ].join(' ');
    return [
      item.seriesName ?? '',
      ep,
      if (item.name.isNotEmpty && !item.name.contains('第')) '- ${item.name}',
    ].where((s) => s.isNotEmpty).join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final engine = _engine;
    final isEpisode = _item?.kind == MediaKind.episode;
    // Windows 沉浸：控制层隐藏时标题栏的窗口按钮也隐藏（不能在 build 里改，画完这一帧再改）
    final immersive = PlatformProfile.isDesktop && !_osd && _error == null;
    if (windowImmersive.value != immersive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) windowImmersive.value = immersive;
      });
    }
    // 面板在这里建好（页面状态变化时才重建），下面随进度每秒重建 4 次的控制层只是把同一个对象传下去：
    // 不然面板里几十张集卡片每秒跟着重建 4 次，电视上选集 / 选资源时卡得动不了
    final Widget? panelChild = switch (_panel) {
      OsdPanel.sources => SourcesPanel(
        serverId: widget.serverId,
        itemId: widget.itemId,
        currentSourceId: _source?.id,
        known: _knownOptions,
        onPick: _switchToOption,
      ),
      OsdPanel.episodes when _episodes != null => EpisodesPanel(
        episodes: _episodes!,
        currentId: widget.itemId,
        onPick: _pickEpisode,
      ),
      _ => null,
    };

    return BackHandler(
      onBack: _handleBack,
      child: Material(
        color: Colors.black,
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: MouseRegion(
            // 控制层隐藏时鼠标指针也隐藏，一动就和控制层一起出来
            cursor: immersive ? SystemMouseCursors.none : MouseCursor.defer,
            onHover: (_) => _showOsd(),
            child: ValueListenableBuilder<bool>(
              valueListenable: MiniPlayerWindow.active,
              builder: (context, mini, _) => Stack(
                fit: StackFit.expand,
                children: [
                  // 画面不参与焦点：安卓上的原生视频画面自带一个铺满全屏、可聚焦的节点，
                  // 从底部按钮按 ↑ 会落到它上面而不是顶部按钮，之后按键都到不了播放页
                  if (engine != null)
                    ExcludeFocus(
                      child: KeyedSubtree(key: ObjectKey(engine), child: engine.buildView()),
                    ),
                  if (engine != null && _danmaku != null && _danmakuVisible && _error == null && !mini)
                    DanmakuLayer(
                      comments: _danmaku!.comments,
                      state: engine.state,
                      config: ref.watch(configProvider.select((c) => c.danmaku)),
                      shift: Duration(milliseconds: _danmakuChoice.shiftMs),
                    ),
                  // 画面：单击暂停 / 播放（打开面板时先关面板）；Windows 双击全屏、右键播放设置
                  Positioned.fill(
                    child: Listener(
                      // Windows：滚轮调音量（向上滚变大）
                      onPointerSignal: (e) {
                        if (e is PointerScrollEvent && PlatformProfile.isDesktop && !mini) {
                          _setVolume(_volume + (e.scrollDelta.dy < 0 ? 0.05 : -0.05));
                        }
                      },
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          if (_panel != OsdPanel.none) {
                            _closePanel();
                          } else {
                            _togglePlay();
                          }
                        },
                        onDoubleTap: PlatformProfile.isDesktop && !mini ? toggleFullScreen : null,
                        onSecondaryTap: mini ? null : _openMenu,
                      ),
                    ),
                  ),
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
                    // 控制层隐藏时不跟着进度（每秒 4 次）重建：看片时界面基本不出帧，
                    // 安卓上每一帧都要和原生视频画面合成一次，弱芯片上会和解码抢资源
                    EngineStateBuilder(
                      state: engine.state,
                      live: mini || _osd || _info || _pendingSeek != null,
                      builder: (context, s) => mini
                          ? MiniPlayerOverlay(
                              state: s,
                              title: _title,
                              onPlayPause: _togglePlay,
                              onClose: () => context.pop(),
                            )
                          : Stack(
                              fit: StackFit.expand,
                              children: [
                                if (s.buffering && _error == null)
                                  const IgnorePointer(
                                    child: Center(
                                      child: SizedBox(
                                        width: 72,
                                        height: 72,
                                        child: CircularProgressIndicator(strokeWidth: 5, color: Colors.white),
                                      ),
                                    ),
                                  ),
                                if (_pendingSeek != null)
                                  IgnorePointer(
                                    child: Center(
                                      child: Glass(
                                        radius: VRadius.panel,
                                        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 20),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (_trickplay case final t?) ...[
                                              TrickplayThumb(trickplay: t, position: _pendingSeek!, width: 400),
                                              const SizedBox(height: 16),
                                            ],
                                            Text(
                                              formatClock(_pendingSeek!),
                                              style: numericStyle(VText.h2.copyWith(fontSize: 44)),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                // 控制层隐藏时不能拿焦点（遥控器焦点回到画面上）
                                ExcludeFocus(
                                  excluding: !_osd,
                                  child: IgnorePointer(
                                    ignoring: !_osd,
                                    child: AnimatedOpacity(
                                      opacity: _osd ? 1 : 0,
                                      duration: VMotion.scroll,
                                      child: FocusTraversalGroup(
                                        child: PlayerOsd(
                                          state: s,
                                          title: _title,
                                          source: _source,
                                          pendingSeek: _pendingSeek,
                                          segments: _segmentList,
                                          danmakuOn: _danmaku != null && _danmakuVisible,
                                          isEpisode: isEpisode,
                                          hasNext: _nextEpisode != null,
                                          panel: _panel,
                                          panelChild: panelChild,
                                          playNode: _playNode,
                                          topNode: _topNode,
                                          onBack: () => context.pop(),
                                          onPlayPause: _togglePlay,
                                          onNext: _playNext,
                                          onSeek: _seekTo,
                                          onDanmaku: _toggleDanmaku,
                                          onDanmakuMenu: _openDanmakuSettings,
                                          onAudio: _openAudioMenu,
                                          onSubtitle: _openSubtitleMenu,
                                          onMore: _openMenu,
                                          onSources: () => _openPanel(OsdPanel.sources),
                                          onEpisodes: () => _openPanel(OsdPanel.episodes),
                                          onRate: _openRateMenu,
                                          onHoverControls: _onHoverControls,
                                          volume: _volume,
                                          muted: _muted,
                                          onVolume: (v) => _setVolume(v, muted: false),
                                          onMute: _toggleMute,
                                          trickplay: _trickplay,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                // 跳过按钮：不随控制层隐藏；控制层显示时让出底部的位置
                                AnimatedPositioned(
                                  duration: VMotion.scroll,
                                  curve: Curves.easeOutCubic,
                                  right: VSpace.safeH,
                                  bottom: _osd ? (_panel == OsdPanel.none ? 250 : 420) : 110,
                                  child: AnimatedSwitcher(
                                    duration: VMotion.focus,
                                    child: _nextCountdown != null
                                        // 「下一集」按钮带 3 秒倒计时（OK / 回车 / 点击立即播放，返回取消）
                                        ? _NextButton(
                                            key: const ValueKey('next-button'),
                                            seconds: _nextCountdown!,
                                            total: nextCountdownSeconds,
                                            onPressed: _playNextNow,
                                          )
                                        : !_skipVisible
                                        ? const SizedBox.shrink()
                                        : _SkipButton(
                                            key: ValueKey('${_skipPrompt!.segment.type}${_skipPrompt!.segment.start}'),
                                            action: _skipPrompt!,
                                            onPressed: _activateSkip,
                                          ),
                                  ),
                                ),
                                if (_info)
                                  Positioned(
                                    right: VSpace.safeH,
                                    top: 150,
                                    child: _InfoPanel(
                                      state: s,
                                      engine: engine.kind,
                                      source: _source,
                                      request: _request,
                                      segments: _segmentList,
                                      danmaku: _danmaku == null
                                          ? (_danmakuError ?? (_danmakuLoading ? '加载中…' : null))
                                          : '${_danmaku!.comments.length} 条 · ${_danmaku!.source}',
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  // 滑块调整（Windows）：盖在最上层；调字幕位置时画面上还有位置预览框
                  if (engine != null && _adjusting != null && !mini)
                    Positioned.fill(
                      child: SliderAdjuster(
                        key: ValueKey(_adjusting),
                        spec: switch (_adjusting!) {
                          _Adjusting.subtitlePosition => SliderSpec.subtitleLift,
                          _Adjusting.subtitleDelay => SliderSpec.subtitleDelay,
                          _Adjusting.danmakuShift => SliderSpec.danmakuShift,
                          _Adjusting.audioDelay => SliderSpec.audioDelay,
                        },
                        value: _adjustInitial,
                        subtitleScale: _adjusting == _Adjusting.subtitlePosition
                            ? ref.read(configProvider).playback.subtitleScale
                            : null,
                        onChanged: _previewAdjust,
                        onDone: _finishAdjust,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 跟随播放状态重建。[live] 为 false（控制层隐藏）时只在缓冲状态变化时重建，进度变化不重建；
/// 上层重建（显示控制层等）时总是拿最新状态
class EngineStateBuilder extends StatefulWidget {
  const EngineStateBuilder({super.key, required this.state, required this.live, required this.builder});

  final ValueListenable<EngineState> state;
  final bool live;
  final Widget Function(BuildContext context, EngineState state) builder;

  @override
  State<EngineStateBuilder> createState() => _EngineStateBuilderState();
}

class _EngineStateBuilderState extends State<EngineStateBuilder> {
  late EngineState _built = widget.state.value;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
  }

  @override
  void didUpdateWidget(EngineStateBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state)) {
      oldWidget.state.removeListener(_onState);
      widget.state.addListener(_onState);
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    if (widget.live || widget.state.value.buffering != _built.buffering) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _built = widget.state.value);
}

/// 媒体信息叠加层（I 键 / 菜单 → 媒体信息）
class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.state,
    required this.engine,
    required this.source,
    required this.request,
    this.segments = const [],
    this.danmaku,
  });

  final List<Segment> segments;
  final String? danmaku;

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
      if (state.droppedFrames != null) ('丢帧', '${state.droppedFrames} 帧'),
      if (v.width != null) ('分辨率', '${v.width} × ${v.height}'),
      if (v.frameRate != null) ('帧率', '${v.frameRate!.toStringAsFixed(3)} fps'),
      ('动态范围', v.hdr ?? source?.rangeLabel ?? 'SDR'),
      if (v.codec != null) ('视频编码', v.codec!),
      if (state.audio != null) ('音轨', state.audio!.displayName),
      if (state.audioOutput != null) ('音频输出', state.audioOutput!),
      if (source?.bitrate != null) ('码率', '${(source!.bitrate! / 1000000).toStringAsFixed(2)} Mbps'),
      ('缓冲', '${(state.buffered - state.position).inSeconds} 秒'),
      if (request != null) ('播放 UA', request!.userAgent),
      if (danmaku != null) ('弹幕', danmaku!),
      for (final seg in segments)
        (
          segmentTypeName(seg.type),
          '${formatClock(seg.start)} – ${formatClock(seg.end)} · ${segmentProviderName(seg.provider)}',
        ),
    ];
    return Glass(
      width: 620,
      radius: VRadius.panel,
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
        radius: VRadius.panel,
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
                  ? '服务器拒绝了播放请求：检查「设置 → 媒体服务器」里的播放 UA / 客户端名称，或重新登录。'
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

/// 片尾自动下一集：白色「下一集」按钮（和「跳过片头」一样），左边的圆环和数字同步倒计时，结束后播放下一集
class _NextButton extends StatelessWidget {
  const _NextButton({super.key, required this.seconds, required this.total, required this.onPressed});

  final int seconds;
  final int total;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF0B0C10);
    return ExcludeFocus(
      child: GestureDetector(
        onTap: onPressed,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 24, 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 30, offset: Offset(0, 8))],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 34,
                  height: 34,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // 圆环在每一秒里连续走完，不是一秒跳一格
                      TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 1, end: (seconds - 1).clamp(0, total) / total),
                        duration: const Duration(seconds: 1),
                        builder: (context, v, _) => CircularProgressIndicator(
                          value: v,
                          strokeWidth: 3,
                          color: ink,
                          backgroundColor: const Color(0x260B0C10),
                        ),
                      ),
                      Text(
                        '$seconds',
                        style: numericStyle(const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: ink)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  '下一集',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: ink),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.skip_next_rounded, size: 30, color: ink),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 跳过片头 / 前情提要 / 片尾、下一集（电视上按 OK，电脑上点击或按回车）
class _SkipButton extends StatelessWidget {
  const _SkipButton({super.key, required this.action, required this.onPressed});

  final SegmentSkipAction action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final next = action.kind == SegmentSkipActionKind.nextEpisode;
    final label = next ? '下一集' : '跳过${segmentTypeName(action.segment.type)}';
    return GestureDetector(
      onTap: onPressed,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.fromLTRB(30, 16, 22, 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(999),
            boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 30, offset: Offset(0, 8))],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: Color(0xFF0B0C10)),
              ),
              const SizedBox(width: 8),
              Icon(
                next ? Icons.skip_next_rounded : Icons.fast_forward_rounded,
                size: 30,
                color: const Color(0xFF0B0C10),
              ),
              const SizedBox(width: 14),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0x590B0C10)),
                  borderRadius: BorderRadius.circular(VRadius.xs),
                ),
                child: Text(
                  PlatformProfile.isTv ? 'OK' : 'Enter',
                  style: const TextStyle(fontSize: 16, color: Color(0xA60B0C10), fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 播放页里用滑块调整的项（Windows）
enum _Adjusting { subtitlePosition, subtitleDelay, danmakuShift, audioDelay }
