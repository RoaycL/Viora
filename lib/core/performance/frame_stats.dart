import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../ui/widgets/cached_image.dart';
import '../../app/tv_performance.dart';
import '../log/app_log.dart';

/// Opt-in development measurement. No per-frame logging or release callback.
class FrameStats with WidgetsBindingObserver {
  static final instance = FrameStats();
  static const enabled = bool.fromEnvironment('VIORA_FRAME_STATS') && !kReleaseMode;
  final _window = FrameStatsWindow();
  Timer? _timer;
  bool _installed = false;
  String _scene = 'startup';

  void start() {
    if (!enabled || _installed) return;
    _installed = true;
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _flush());
    AppLog.add('[perf] enabled; Flutter slow frames and video dropped frames are separate metrics');
  }

  void scene(String name) {
    if (!enabled || name == _scene) return;
    _flush();
    _scene = name;
  }

  void _onTimings(List<FrameTiming> frames) {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    final hz = view?.display.refreshRate ?? 60;
    final budget = 1000000 / (hz > 0 ? hz : 60);
    for (final frame in frames) {
      _window.add(frame.buildDuration, frame.rasterDuration, frame.totalSpan, budgetUs: budget);
    }
  }

  void _flush() {
    final summary = _window.takeSummary();
    if (summary == null) return;
    final cache = PaintingBinding.instance.imageCache;
    AppLog.add(
      '[perf] mode=${TvPerformance.baseline ? 'baseline' : 'optimized'} scene=$_scene $summary '
      'images=${cache.currentSize} decoded_cache_mb=${(cache.currentSizeBytes / (1024 * 1024)).toStringAsFixed(1)} '
      'live_images=${cache.liveImageCount} pending_images=${cache.pendingImageCount} '
      'downloads=${CachedNetImage.activeDownloads} queued=${CachedNetImage.queuedDownloads}',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => _flush());
    } else {
      _timer?.cancel();
      _timer = null;
      _flush();
    }
  }
}

/// Bounded samples; percentile work happens once per logging interval.
class FrameStatsWindow {
  static const maxSamples = 1024;
  final _build = <int>[];
  final _raster = <int>[];
  final _total = <int>[];
  int _frames = 0;
  int _slow = 0;
  int _maxBuild = 0;
  int _maxRaster = 0;
  double _budget = 16666.7;

  void add(Duration build, Duration raster, Duration total, {required double budgetUs}) {
    _frames++;
    _budget = budgetUs;
    if (build.inMicroseconds > budgetUs || raster.inMicroseconds > budgetUs) _slow++;
    _maxBuild = math.max(_maxBuild, build.inMicroseconds);
    _maxRaster = math.max(_maxRaster, raster.inMicroseconds);
    if (_build.length < maxSamples) {
      _build.add(build.inMicroseconds);
      _raster.add(raster.inMicroseconds);
      _total.add(total.inMicroseconds);
    }
  }

  String? takeSummary() {
    if (_frames == 0) return null;
    String ms(num us) => (us / 1000).toStringAsFixed(2);
    String p95(List<int> samples) {
      samples.sort();
      return ms(samples[(samples.length * 0.95).ceil() - 1]);
    }

    final result =
        'frames=$_frames slow=$_slow budget_ms=${ms(_budget)} '
        'build_p95_ms=${p95(_build)} build_max_ms=${ms(_maxBuild)} '
        'raster_p95_ms=${p95(_raster)} raster_max_ms=${ms(_maxRaster)} total_p95_ms=${p95(_total)}';
    _frames = _slow = _maxBuild = _maxRaster = 0;
    _build.clear();
    _raster.clear();
    _total.clear();
    return result;
  }
}
