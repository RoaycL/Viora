import '../domain/models/segment.dart';
import '../domain/models/segment_settings.dart';
import '../domain/usecases/segment_resolver.dart';
import 'manual_segments.dart';
import 'segment_skip_controller.dart';

/// Adapter for the planned PlaySession: begin after engine.open, feed position
/// events and render onPrompt. Lookup never blocks engine startup.
class SegmentPlaybackSession {
  SegmentPlaybackSession({
    required this.resolver,
    required this.seek,
    required this.nextEpisode,
    required this.onPrompt,
    this.onResolution,
    this.onActionError,
    this.onAutoSkip,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  final SegmentResolver resolver;
  final Future<void> Function(Duration) seek;
  final Future<void> Function() nextEpisode;
  final void Function(SegmentSkipAction?) onPrompt;
  final void Function(SegmentResolution)? onResolution;
  final void Function(Object)? onActionError;

  /// 自动跳过发生时（界面提示"已跳过片头"）
  final void Function(SegmentSkipAction)? onAutoSkip;
  int _generation = 0;
  SegmentSkipController? _controller;
  Duration _position = Duration.zero;

  /// 是否已经拿到真实的播放位置。没拿到之前片段解析好了也不做判断：
  /// 否则续播（如从 10 分钟处开始）时会按位置 0 命中片头、被自动跳回片头结尾
  bool _hasPosition = false;
  bool _inFlight = false;

  /// 刚发出的跳转：等播放位置真的到了目标才算完成。内核刚打开文件、还没加载好时（自动连播到下一集、
  /// 手动标记立即可用）mpv 会丢掉跳转命令而不报错，这时隔一会儿重发，最多 [maxSeekAttempts] 次
  SegmentSkipAction? _verifying;
  int _seekAttempts = 0;
  DateTime _seekSentAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const maxSeekAttempts = 4;
  static const seekRetryAfter = Duration(milliseconds: 1500);

  /// 数据源解析出的片段，和手动标记（优先）
  List<Segment> _resolved = const [];
  List<Segment> _manual = const [];

  /// [position]：当前确定的播放位置（还没开始播放时传 null，等第一次 [onPosition]）
  /// [manual]：手动标记的片段，优先于数据源（同类型替换）
  void begin(
    SegmentQuery query,
    SegmentSettings settings, {
    bool hasNextEpisode = false,
    Duration? position,
    List<Segment> manual = const [],
  }) {
    final generation = ++_generation;
    _position = position ?? Duration.zero;
    _hasPosition = position != null;
    _inFlight = false;
    _verifying = null;
    _resolved = const [];
    _manual = manual;
    final controller = SegmentSkipController(query: query, settings: settings, hasNextEpisode: hasNextEpisode);
    _controller = controller;
    onPrompt(null);
    if (manual.isNotEmpty) {
      controller.segments = manual;
      onResolution?.call(SegmentResolution(segments: manual));
    }
    void apply(SegmentResolution result) {
      if (generation != _generation) return;
      _resolved = result.segments;
      final merged = mergeManualSegments(_resolved, _manual);
      controller.segments = merged;
      onResolution?.call(SegmentResolution(segments: merged, failures: result.failures, fromCache: result.fromCache));
      if (_hasPosition) onPosition(_position);
    }

    resolver
        .resolve(query, onPartial: apply)
        .then(
          apply,
          onError: (Object error) {
            if (generation == _generation) onActionError?.call(error);
          },
        );
  }

  /// 播放中修改了手动标记：立即生效。当前位置正好落在新标记的片段里时本次不触发跳过
  /// （刚标完片尾开始就被自动跳到下一集会很突兀），从下一集 / 下次播放开始生效
  void setManual(List<Segment> manual) {
    final controller = _controller;
    if (controller == null) return;
    _manual = manual;
    final merged = mergeManualSegments(_resolved, manual);
    controller.segments = merged;
    for (final m in manual.where((m) => m.contains(_position))) {
      controller.markHandled(SegmentSkipAction(segment: m, kind: SegmentSkipActionKind.seek, automatic: false));
    }
    onResolution?.call(SegmentResolution(segments: merged));
    if (_hasPosition) onPosition(_position);
  }

  void onPosition(Duration position) {
    _position = position;
    _hasPosition = true;
    if (_inFlight) return;
    if (_verifying != null && _checkSeek(position)) return;
    final action = _controller?.at(position);
    if (action != null && action.automatic) {
      onAutoSkip?.call(action);
      activate(action);
    } else {
      onPrompt(action);
    }
  }

  Future<void> activate(SegmentSkipAction action) async {
    final controller = _controller;
    final generation = _generation;
    if (controller == null || _inFlight || controller.at(_position)?.segment != action.segment) {
      return;
    }
    _inFlight = true;
    controller.markHandled(action);
    onPrompt(null);
    try {
      if (action.kind == SegmentSkipActionKind.nextEpisode) {
        await nextEpisode();
      } else {
        await seek(action.target);
        if (generation == _generation) {
          _verifying = action;
          _seekAttempts = 1;
          _seekSentAt = _now();
        }
      }
    } on Exception catch (error) {
      if (generation == _generation) {
        // Present a manual retry; never loop a failing seek on every tick.
        controller.retry(action);
        onPrompt(SegmentSkipAction(segment: action.segment, kind: action.kind, automatic: false));
        onActionError?.call(error);
      }
    } finally {
      if (generation == _generation) _inFlight = false;
    }
  }

  /// 返回 true：跳转还没生效、正在等待或已重发，这次位置不再做别的判断
  bool _checkSeek(Duration position) {
    final action = _verifying!;
    final segment = action.segment;
    // 到了目标附近，或用户自己拖走了：完成
    if (position >= action.target - const Duration(seconds: 1) || !segment.contains(position)) {
      _verifying = null;
      return false;
    }
    if (_now().difference(_seekSentAt) < seekRetryAfter) return true;
    if (_seekAttempts >= maxSeekAttempts) {
      _verifying = null;
      onActionError?.call(StateError('跳过${segment.type.name}未生效：位置停在 ${position.inSeconds}s'));
      return false;
    }
    _seekAttempts++;
    _seekSentAt = _now();
    final generation = _generation;
    _inFlight = true;
    seek(action.target)
        .catchError((Object e) {
          if (generation == _generation) onActionError?.call(e);
        })
        .whenComplete(() {
          if (generation == _generation) _inFlight = false;
        });
    return true;
  }

  void dispose() {
    _generation++;
    _controller = null;
    onPrompt(null);
  }
}
