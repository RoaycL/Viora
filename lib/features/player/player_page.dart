import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/input/intents.dart';
import '../../app/platform_profile.dart';
import '../../app/theme.dart';
import '../../app/window_frame.dart';
import '../../data/aggregate/sources.dart';
import '../../data/config/app_config.dart';
import '../../data/config/config_store.dart';
import '../../data/danmaku/danmaku_client.dart';
import '../../data/danmaku/danmaku_models.dart';
import '../../data/emby/emby_client.dart';
import '../../data/history/play_history.dart';
import '../../data/media/media_models.dart';
import '../../data/media/server_registry.dart';
import '../../player/engine.dart';
import '../../player/exo_engine.dart';
import '../../player/mpv_engine.dart';
import '../../player/playback_cache.dart';
import '../../player/preload.dart';
import '../../player/manual_segments.dart';
import '../../player/segment_playback_session.dart';
import '../../player/segment_skip_controller.dart';
import '../../domain/models/segment.dart';
import '../../data/index/media_index.dart';
import '../segments/segment_service.dart';
import '../danmaku/danmaku_layer.dart';
import '../danmaku/danmaku_service.dart';
import 'mini_player.dart';
import 'player_osd.dart';
import '../../ui/widgets/form.dart';
import '../../ui/panels/form_dialog.dart';
import '../../ui/glass/glass.dart';
import '../../ui/scale/design_scale.dart';
import '../../ui/panels/context_menu.dart';
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
    return _nextEpisodeFuture ??= client
        .episodes(item.seriesId!)
        .then((all) => _nextEpisode ??= nextEpisodeAfter(all, item))
        .catchError((Object _) {
          _nextEpisodeFuture = null; // 失败了下次再查
          return null;
        });
  }

  bool _nextPreloading = false;

  /// 控制层底部的面板（播放资源 / 选集）
  OsdPanel _panel = OsdPanel.none;
  Future<List<MediaItem>>? _episodes;

  /// 鼠标停在控制栏上（Windows）
  bool _hoverControls = false;
  final _playNode = FocusNode(debugLabel: 'osd-play');

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
    );
  }

  PlayerEngine _createEngine({bool forceMpv = false, bool forceExo = false}) {
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

  void _onEngineState() {
    final s = _state;
    // 开始播放前内核报的位置可能还是 0（续播时还没跳到上次的位置），不能拿来判断片头
    if (_started || s.playing) _segments?.onPosition(s.position);
    if (!_nextPreloading &&
        s.duration > Duration.zero &&
        s.position.inMilliseconds > s.duration.inMilliseconds * 0.85) {
      _preloadNext();
    }
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
      // 并行：创建播放内核、取条目信息、取播放信息（详情页 / 首页已预加载时直接命中缓存）
      _cacheDir ??= await PlaybackCache.dir();
      final engineReady = _engine == null ? _attachEngine(_createEngine()) : Future<void>.value();
      final itemFuture = _item == null ? client.item(widget.itemId) : Future.value(_item!);
      itemFuture.ignore();
      final info = await PlaybackPreloader.info(client, widget.serverId, widget.itemId);
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
      await engineReady;
      await _openCurrent(at ?? Duration(milliseconds: widget.startMs));
      _item = await itemFuture;
      if (mounted) setState(() {});
      unawaited(_beginSegments());
      unawaited(_beginDanmaku());
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
    // 本机也记一份上次播放时间（部分服务器的继续观看不带 LastPlayedDate）
    PlayHistory.record(widget.serverId, widget.itemId);
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
      // 页面销毁时不能再用 ref（Riverpod 会抛错并打断后续的关闭播放器），用提前保存的容器；
      // 等服务器记下进度后再刷新继续观看 / 详情
      final container = _container;
      final key = (serverId: widget.serverId, itemId: widget.itemId);
      Future(() => client.reportStopped(source, _state.position, _playSessionId)).catchError((_) {}).whenComplete(() {
        container?.invalidate(resumeProvider);
        container?.invalidate(itemProvider(key));
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
    if (mounted) {
      setState(() {
        _skipPrompt = null;
        _segmentList = const [];
      });
    }
  }

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
          client.item(item.seriesId!).then<Object?>((v) => v, onError: (_) => null),
          _resolveNextEpisode(),
        ]);
        if (results[0] is MediaItem) title = results[0]! as MediaItem;
        hasNext = results[1] != null;
      }
      final duration = source.duration ?? item.runtime ?? _state.duration;
      if (duration <= Duration.zero || !mounted) return;
      final query = SegmentQuery(
        titleKey: titleKeyOf(title),
        kind: item.kind == MediaKind.movie ? SegmentMediaKind.movie : SegmentMediaKind.episode,
        duration: duration,
        tmdbId: int.tryParse(title.tmdbId ?? ''),
        imdbId: title.imdbId,
        season: item.seasonNumber,
        episode: item.episodeNumber,
        sourceKey: '${widget.serverId}/${source.id}',
      );
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
              final next = _nextEpisode;
              if (next != null && mounted) _handoffTo('/play/${widget.serverId}/${next.id}?pos=0');
            },
            onPrompt: (action) {
              if (!mounted || _samePrompt(action, _skipPrompt)) return;
              setState(() => _skipPrompt = action);
            },
            onResolution: (r) {
              if (mounted) setState(() => _segmentList = r.segments);
            },
            onAutoSkip: (action) => showToast(_autoSkipText(action)),
            onActionError: (e) => debugPrint('segments: $e'),
          )..begin(
            query,
            settings,
            hasNextEpisode: hasNext,
            position: _started ? _state.position : null,
            manual: mark.segmentsFor(duration),
          );
    } catch (e) {
      debugPrint('segments unavailable: $e');
    }
  }

  // ───────────────────────── 弹幕 ─────────────────────────

  DanmakuClient? get _danmakuClient {
    final c = ref.read(configProvider).danmaku;
    return c.activeServers.isEmpty ? null : DanmakuClient(c);
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
    if (ref.read(configProvider).danmaku.activeServers.isEmpty) return '未配置服务器';
    return _danmakuError == null ? '未加载' : '未匹配';
  }

  Future<void> _openDanmakuMenu() async {
    final client = _danmakuClient;
    final target = _danmakuTarget ?? (_item == null ? null : DanmakuTarget.of(_item!));
    if (client == null || target == null) {
      showToast('还没有配置弹幕服务器：设置 → 弹幕');
      return;
    }
    _danmakuTarget ??= target;
    final shift = _danmakuChoice.shiftMs;
    final style = ref.read(configProvider).danmaku;
    await showContextMenu(
      context,
      title: _danmaku == null ? '弹幕' : '弹幕 · ${_danmaku!.source}',
      actions: [
        if (_danmaku != null)
          MenuAction(
            _danmakuVisible ? '隐藏弹幕' : '显示弹幕',
            _danmakuVisible ? Icons.speaker_notes_off_outlined : Icons.speaker_notes_outlined,
            _toggleDanmaku,
          ),
        // 显示样式：改完立即作用在屏幕上的弹幕，并保存到「设置 → 弹幕」
        MenuAction(
          '显示区域 · ${DanmakuConfig.labelOf(DanmakuConfig.areaOptions, style.area)}',
          Icons.height_rounded,
          () => _pickDanmakuStyle('显示区域', DanmakuConfig.areaOptions, style.area, (c, v) => c.copyWith(area: v)),
        ),
        MenuAction(
          '字号 · ${DanmakuConfig.labelOf(DanmakuConfig.fontOptions, style.fontSize)}',
          Icons.format_size_rounded,
          () => _pickDanmakuStyle('字号', DanmakuConfig.fontOptions, style.fontSize, (c, v) => c.copyWith(fontSize: v)),
        ),
        MenuAction(
          '不透明度 · ${DanmakuConfig.labelOf(DanmakuConfig.opacityOptions, style.opacity)}',
          Icons.opacity_rounded,
          () =>
              _pickDanmakuStyle('不透明度', DanmakuConfig.opacityOptions, style.opacity, (c, v) => c.copyWith(opacity: v)),
        ),
        MenuAction(
          '速度 · ${DanmakuConfig.labelOf(DanmakuConfig.speedOptions, style.speed)}',
          Icons.speed_rounded,
          () => _pickDanmakuStyle('滚动速度', DanmakuConfig.speedOptions, style.speed, (c, v) => c.copyWith(speed: v)),
        ),
        MenuAction('搜索「${target.title}」并选择', Icons.manage_search_rounded, () => _searchDanmaku(target.title)),
        MenuAction('按关键词搜索…', Icons.keyboard_rounded, () => _searchDanmakuByKeyword(target.title)),
        MenuAction(
          '时间偏移 · ${shift == 0 ? '无' : '${shift > 0 ? '+' : ''}${(shift / 1000).toStringAsFixed(1)} 秒'}',
          Icons.schedule_rounded,
          () => showContextMenu(
            context,
            title: '弹幕时间偏移（当前 ${(shift / 1000).toStringAsFixed(1)} 秒）',
            actions: [
              for (final d in const [-5000, -1000, -500, 500, 1000, 5000])
                MenuAction(
                  '${d > 0 ? '延后' : '提前'} ${(d.abs() / 1000).toStringAsFixed(1)} 秒',
                  d > 0 ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
                  () => _setDanmakuShift(_danmakuChoice.shiftMs + d),
                ),
              MenuAction('重置', Icons.restart_alt_rounded, () => _setDanmakuShift(0)),
            ],
          ),
        ),
        MenuAction(
          '重新自动匹配',
          Icons.refresh_rounded,
          () => _loadDanmaku(() => resolveDanmaku(client, target, choice: _danmakuChoice), announce: true),
        ),
      ],
    );
    if (mounted) _focus.requestFocus();
  }

  /// 选一个弹幕样式（显示区域 / 字号 / 不透明度 / 速度）；选完回到上一级弹幕菜单，方便接着调
  Future<void> _pickDanmakuStyle(
    String title,
    List<(double, String)> options,
    double current,
    DanmakuConfig Function(DanmakuConfig, double) apply,
  ) async {
    var picked = false;
    await showContextMenu(
      context,
      title: '弹幕$title',
      actions: [
        for (final (v, label) in options)
          MenuAction('$label${v == current ? '  ✓' : ''}', Icons.chat_outlined, () {
            picked = true;
            if (!_danmakuVisible) setState(() => _danmakuVisible = true);
            ref.read(configProvider.notifier).update((c) => c.copyWith(danmaku: apply(c.danmaku, v)));
          }),
      ],
    );
    if (picked && mounted) await _openDanmakuMenu();
  }

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
      title: '选择作品 · ${animes.length} 个结果',
      actions: [
        for (final a in animes.take(40))
          MenuAction(
            '${a.title}${a.episodeCount == null ? '' : ' · ${a.episodeCount} 集'}',
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
    SegmentType.intro => '已自动跳过片头',
    SegmentType.recap => '已自动跳过前情提要',
    SegmentType.credits => '已自动跳过片尾',
    SegmentType.preview => '已自动跳过预告',
  };

  void _activateSkip() {
    final action = _skipPrompt;
    if (action != null) _segments?.activate(action);
  }

  void _handoffTo(String route) {
    _handoff = true;
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

  Future<void> _onCompleted() async {
    _reportStopped();
    final item = _item, client = _client;
    if (item == null || client == null || !mounted) return;
    // 剧集自动播放下一集（季末接着播下一季第一集）
    final next = await _resolveNextEpisode();
    if (!mounted) return;
    if (next != null) {
      _handoffTo('/play/${widget.serverId}/${next.id}?pos=0');
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
    _focus.dispose();
    _playNode.dispose();
    // 退出播放时恢复窗口；连播下一集 / 换服务器时保持小窗
    if (!handoff) MiniPlayerWindow.exit();
    super.dispose();
  }

  // ───────────────────────── 操作 ─────────────────────────

  /// 焦点在控制层的按钮上（电视用遥控器移进去的，或 Windows 鼠标悬停）
  bool get _onControls => !_focus.hasPrimaryFocus && _focus.hasFocus;

  void _showOsd({bool sticky = false}) {
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
  void _focusControls() {
    _showOsd();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playNode.requestFocus();
    });
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

  /// 进度条点击 / 拖动（Windows）
  void _seekTo(Duration to) {
    _seekTimer?.cancel();
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

  /// 返回键：关面板 → 焦点回到画面 → 关媒体信息 → 退出小窗 / 全屏（Windows）→ 隐藏控制层 → 退出播放
  Future<void> _back() async {
    if (_panel != OsdPanel.none) {
      _closePanel();
      return;
    }
    if (PlatformProfile.isTv && _onControls) {
      _focus.requestFocus();
      return;
    }
    if (_info) {
      setState(() => _info = false);
      return;
    }
    if (PlatformProfile.isDesktop) {
      if (MiniPlayerWindow.active.value) return MiniPlayerWindow.exit();
      if (windowFullScreen.value) return toggleFullScreen();
    }
    if (_osd && _state.playing) {
      setState(() => _osd = false);
      return;
    }
    if (mounted) context.pop();
  }

  static bool _isBack(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.goBack ||
      key == LogicalKeyboardKey.escape ||
      key == LogicalKeyboardKey.gameButtonB ||
      key == LogicalKeyboardKey.backspace;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final repeat = event is KeyRepeatEvent;

    if (_isBack(key)) {
      if (!repeat) _back();
      return KeyEventResult.handled;
    }
    if (_onControls) {
      if (PlatformProfile.isTv) {
        // 电视：焦点在按钮 / 面板上时，方向键移动焦点、OK 点击，交给按钮处理
        _showOsd();
        return KeyEventResult.ignored;
      }
      // Windows：鼠标悬停让按钮拿到了焦点，回车照常点击按钮，其他快捷键仍然作用于播放器
      if (confirmKeys.contains(key)) return KeyEventResult.ignored;
      _focus.requestFocus();
    }

    final step = Duration(seconds: ref.read(configProvider).playback.seekStepSeconds);
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
    } else if (confirmKeys.contains(key) && _skipPrompt != null) {
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
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _showOsd();
    } else if (key == LogicalKeyboardKey.arrowDown) {
      // 电视：焦点移到底部按钮行；Windows：打开播放设置菜单
      PlatformProfile.isTv ? _focusControls() : _openMenu();
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
    _handoffTo('/play/${widget.serverId}/${next.id}?pos=0');
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
    if (!mounted) return;
    (restore != null && restore.context != null && restore.context!.mounted ? restore : _focus).requestFocus();
    _armOsdTimer();
  }

  Future<void> _openAudioMenu() => _menu(() {
    final s = _state;
    if (s.audioTracks.isEmpty) {
      showToast('没有可选的音轨');
      return Future.value();
    }
    return showContextMenu(
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
  });

  Future<void> _openSubtitleMenu() => _menu(() {
    final s = _state;
    final external = _source?.subtitles.where((x) => x.isExternal).toList() ?? const <MediaStreamInfo>[];
    return showContextMenu(
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
        MenuAction('在线搜索字幕…', Icons.travel_explore_rounded, _searchOnlineSubtitles),
      ],
    );
  });

  // ───────────────────────── 在线字幕 ─────────────────────────

  /// 让媒体服务器用它的字幕插件（OpenSubtitles 等）在线搜索；下载后服务器保存在视频旁边，下次播放也能直接用
  Future<void> _searchOnlineSubtitles() => _menu(
    () => showContextMenu(
      context,
      title: '在线搜索字幕',
      actions: [
        MenuAction('中文字幕', Icons.translate_rounded, () => _searchSubtitles('chi', '中文')),
        MenuAction('英文字幕', Icons.translate_rounded, () => _searchSubtitles('eng', '英文')),
      ],
    ),
  );

  Future<void> _searchSubtitles(String language, String label) async {
    final client = _client, item = _item;
    if (client == null || item == null) return;
    showToast('正在搜索$label字幕…');
    List<RemoteSubtitle> list;
    try {
      list = await client.searchSubtitles(item.id, language);
    } catch (e) {
      final denied = e is MediaServerException && (e.statusCode == 401 || e.statusCode == 403);
      showToast(denied ? '当前账号没有字幕管理权限：请在服务器的用户设置里允许管理字幕' : '搜索字幕失败：$e');
      return;
    }
    if (!mounted) return;
    if (list.isEmpty) {
      showToast('没有找到$label字幕（服务器需要安装 OpenSubtitles 等字幕插件）');
      return;
    }
    await _menu(
      () => showContextMenu(
        context,
        title: '$label字幕 · ${list.length} 个结果',
        actions: [
          for (final r in list.take(40))
            MenuAction(
              [
                r.name,
                r.provider,
                ?r.format?.toUpperCase(),
                if (r.downloads != null) '${r.downloads} 次下载',
              ].where((x) => x.isNotEmpty).join(' · '),
              Icons.closed_caption_outlined,
              () => _downloadSubtitle(r),
            ),
        ],
      ),
    );
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
      final req = client.subtitle(updated, x);
      if (req == null) return;
      await _engine?.addExternalSubtitle(req.url, title: x.displayName, language: x.language);
      showToast('已加载字幕：${x.displayName}');
    } catch (e) {
      showToast('下载字幕失败：$e');
    }
  }

  /// 手动标记片头 / 片尾：以当前播放位置为准，剧集同一季各集通用
  Future<void> _openMarkMenu() => _menu(() {
    final query = _segmentQuery;
    if (query == null) return Future.value();
    final pos = _state.position;
    final duration = query.duration;
    final m = _manualMark;
    final scope = query.kind == SegmentMediaKind.episode ? '第 ${query.season ?? 0} 季各集通用' : '这部电影';
    String clock(Duration d) => formatClock(d);
    return showContextMenu(
      context,
      title: '片头片尾标记（$scope）',
      actions: [
        MenuAction(
          '片头到这里结束（${clock(pos)}）${m.introEnd == null ? '' : '  · 现为 ${clock(m.introEnd!)}'}',
          Icons.first_page_rounded,
          () {
            if (pos <= (m.introStart ?? Duration.zero)) {
              showToast('片头结束要在片头开始之后');
              return;
            }
            _saveMark(m.copyWith(introEnd: pos), '片头 ${clock(m.introStart ?? Duration.zero)}–${clock(pos)}');
          },
        ),
        MenuAction(
          '片头从这里开始（${clock(pos)}）${m.introStart == null ? '  · 默认从 00:00' : '  · 现为 ${clock(m.introStart!)}'}',
          Icons.start_rounded,
          () {
            // 有些剧先放一段正片再进片头：片头开始后移；已有的结束点在它之前就作废
            final end = m.introEnd;
            final next = end != null && end <= pos
                ? ManualMark(introStart: pos, creditsFromEnd: m.creditsFromEnd)
                : m.copyWith(introStart: pos);
            _saveMark(next, '片头从 ${clock(pos)} 开始${next.introEnd == null ? '，请再标记片头结束' : ''}');
          },
        ),
        MenuAction(
          '片尾从这里开始（${clock(pos)}）${m.creditsFromEnd == null ? '' : '  · 现为结尾前 ${clock(m.creditsFromEnd!)}'}',
          Icons.last_page_rounded,
          () {
            if (pos >= duration || (m.introEnd != null && pos <= m.introEnd!)) {
              showToast('片尾开始要在片头之后、结尾之前');
              return;
            }
            _saveMark(m.copyWith(creditsFromEnd: duration - pos), '片尾从结尾前 ${clock(duration - pos)} 开始');
          },
        ),
        if (m.introEnd != null || m.introStart != null)
          MenuAction('清除片头标记', Icons.backspace_outlined, () => _saveMark(m.copyWith(clearIntro: true), '已清除片头标记')),
        if (m.creditsFromEnd != null)
          MenuAction('清除片尾标记', Icons.backspace_outlined, () => _saveMark(m.copyWith(clearCredits: true), '已清除片尾标记')),
      ],
    );
  });

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

  Future<void> _openRateMenu() => _menu(() {
    final rate = _state.rate;
    return showContextMenu(
      context,
      title: '倍速',
      actions: [
        for (final r in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0])
          MenuAction('${r}x${rate == r ? '  ✓' : ''}', Icons.speed_rounded, () => _engine?.setRate(r)),
      ],
    );
  });

  /// 「更多」：完整的播放设置菜单
  Future<void> _openMenu() => _menu(() {
    final s = _state;
    final engine = _engine;
    return showContextMenu(
      context,
      title: '播放设置',
      actions: [
        MenuAction('音轨 · ${s.audioTracks.length} 条', Icons.audiotrack_rounded, _openAudioMenu),
        MenuAction('字幕 · ${s.subtitleTracks.length} 条', Icons.subtitles_rounded, _openSubtitleMenu),
        MenuAction('弹幕 · $_danmakuStatus', Icons.chat_outlined, _openDanmakuMenu),
        MenuAction('切换资源（所有服务器）', Icons.swap_horiz_rounded, () => _openPanel(OsdPanel.sources)),
        if (_item?.kind == MediaKind.episode)
          MenuAction('选集', Icons.video_library_outlined, () => _openPanel(OsdPanel.episodes)),
        MenuAction('倍速 · ${s.rate}x', Icons.speed_rounded, _openRateMenu),
        if (_segmentQuery != null)
          MenuAction('片头片尾标记${_manualMark.isEmpty ? '' : ' · 已标记'}', Icons.bookmark_add_outlined, _openMarkMenu),
        if (ExoEngine.supported && engine != null)
          MenuAction(
            '播放内核 · ${engine.kind.label}（切换到 ${engine.kind == EngineKind.exo ? 'mpv' : 'ExoPlayer'}）',
            Icons.memory_rounded,
            () => _switchEngine(forceMpv: engine.kind == EngineKind.exo, forceExo: engine.kind == EngineKind.mpv),
          ),
        MenuAction('媒体信息', Icons.info_outline_rounded, () => setState(() => _info = true)),
      ],
    );
  });

  /// 打开「播放资源」/「选集」面板（替换控制层底部的按钮行）
  void _openPanel(OsdPanel panel) {
    final item = _item;
    if (panel == OsdPanel.episodes) {
      final client = _client;
      if (item == null || client == null || item.seriesId == null) return;
      _episodes ??= client.episodes(item.seriesId!, seasonId: item.seasonId);
    }
    setState(() => _panel = panel);
    _showOsd(sticky: true);
  }

  /// 切换到另一个版本：同一台服务器同一条目直接换源，其他服务器的版本换到那台服务器从当前进度继续
  void _switchToOption(SourceOption o) {
    setState(() => _panel = OsdPanel.none);
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
    _handoffTo('/play/${widget.serverId}/${e.id}?pos=${e.position.inMilliseconds}');
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

    return Material(
      color: Colors.black,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          onHover: (_) => _showOsd(),
          child: ValueListenableBuilder<bool>(
            valueListenable: MiniPlayerWindow.active,
            builder: (context, mini, _) => Stack(
              fit: StackFit.expand,
              children: [
                if (engine != null) KeyedSubtree(key: ObjectKey(engine), child: engine.buildView()),
                if (engine != null && _danmaku != null && _danmakuVisible && _error == null && !mini)
                  DanmakuLayer(
                    comments: _danmaku!.comments,
                    state: engine.state,
                    config: ref.watch(configProvider.select((c) => c.danmaku)),
                    shift: Duration(milliseconds: _danmakuChoice.shiftMs),
                  ),
                // 画面：单击暂停 / 播放（打开面板时先关面板）；Windows 双击全屏、右键播放设置
                Positioned.fill(
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
                    builder: (context, s, _) => mini
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
                                      child: Text(formatClock(_pendingSeek!), style: VText.h2.copyWith(fontSize: 44)),
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
                                        panelChild: switch (_panel) {
                                          OsdPanel.sources => SourcesPanel(
                                            serverId: widget.serverId,
                                            itemId: widget.itemId,
                                            currentSourceId: _source?.id,
                                            onPick: _switchToOption,
                                          ),
                                          OsdPanel.episodes when _episodes != null => EpisodesPanel(
                                            episodes: _episodes!,
                                            currentId: widget.itemId,
                                            onPick: _pickEpisode,
                                          ),
                                          _ => null,
                                        },
                                        playNode: _playNode,
                                        onBack: () => context.pop(),
                                        onPlayPause: _togglePlay,
                                        onNext: _playNext,
                                        onSeek: _seekTo,
                                        onDanmaku: _toggleDanmaku,
                                        onDanmakuMenu: _openDanmakuMenu,
                                        onAudio: _openAudioMenu,
                                        onSubtitle: _openSubtitleMenu,
                                        onMore: _openMenu,
                                        onSources: () => _openPanel(OsdPanel.sources),
                                        onEpisodes: () => _openPanel(OsdPanel.episodes),
                                        onRate: _openRateMenu,
                                        onHoverControls: (v) => _hoverControls = v,
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
                                  child: _skipPrompt == null
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
              ],
            ),
          ),
        ),
      ),
    );
  }
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
      if (v.width != null) ('分辨率', '${v.width} × ${v.height}'),
      if (v.frameRate != null) ('帧率', '${v.frameRate!.toStringAsFixed(3)} fps'),
      ('动态范围', v.hdr ?? source?.rangeLabel ?? 'SDR'),
      if (v.codec != null) ('视频编码', v.codec!),
      if (state.audio != null) ('音轨', state.audio!.displayName),
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
