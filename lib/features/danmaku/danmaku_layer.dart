import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../data/config/app_config.dart';
import '../../data/danmaku/danmaku_models.dart';
import '../../player/engine.dart';

/// 弹幕层：盖在视频上、OSD 下面，不接收点击。
///
/// 位置按"视频时间"计算（内核每 250ms 左右报一次进度，中间按播放速率插值），
/// 所以暂停时弹幕停住、倍速时一起变快、拖动进度后从新位置重新开始。
class DanmakuLayer extends StatefulWidget {
  const DanmakuLayer({
    super.key,
    required this.comments,
    required this.state,
    required this.config,
    this.shift = Duration.zero,
  });

  /// 按时间排好序的弹幕
  final List<DanmakuComment> comments;
  final ValueListenable<EngineState> state;
  final DanmakuConfig config;

  /// 弹幕整体延后（负数 = 提前）
  final Duration shift;

  /// 顶部 / 底部固定弹幕停留的秒数
  static const fixedSeconds = 4.0;

  @override
  DanmakuLayerState createState() => DanmakuLayerState();
}

class _Live {
  _Live(this.comment, this.start, this.lane, this.fill, this.stroke) : width = fill.width;

  final DanmakuComment comment;

  /// 出现的视频时间（秒）；改速度时按当前进度换算，位置不跳
  double start;
  final int lane;

  /// 改字号 / 不透明度时就地重排
  TextPainter fill;
  TextPainter stroke;
  double width;

  void dispose() {
    fill.dispose();
    stroke.dispose();
  }
}

class DanmakuLayerState extends State<DanmakuLayer> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _repaint = _Repaint();

  /// 帧时钟（Ticker 启动以来的时间）：和画面刷新同步
  Duration _elapsed = Duration.zero;
  final _live = <_Live>[];

  int _next = 0;
  bool _reset = true;
  double _lastNow = double.negativeInfinity;
  Size _size = Size.zero;

  // 进度插值
  double _anchorPos = 0;
  Duration _anchorAt = Duration.zero;
  bool _moving = false;
  double _rate = 1;
  double _lastReported = 0;

  double get _videoNow {
    final pos = _moving ? _anchorPos + (_elapsed - _anchorAt).inMicroseconds / 1e6 * _rate : _anchorPos;
    return pos - widget.shift.inMicroseconds / 1e6;
  }

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
    _onState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(DanmakuLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state)) {
      oldWidget.state.removeListener(_onState);
      widget.state.addListener(_onState);
      _onState();
    }
    if (!identical(oldWidget.comments, widget.comments) || oldWidget.shift != widget.shift) {
      _reset = true;
    } else {
      // 播放中调整样式：屏幕上的弹幕就地更新，不清屏
      _restyle(oldWidget.config, widget.config);
    }
    _syncTicker();
  }

  void _restyle(DanmakuConfig old, DanmakuConfig c) {
    var changed = false;
    if (old.fontSize != c.fontSize || old.opacity != c.opacity) {
      for (final l in _live) {
        l.dispose();
        final (fill, stroke) = _paint(l.comment);
        l
          ..fill = fill
          ..stroke = stroke
          ..width = fill.width;
      }
      changed = true;
    }
    if (old.speed != c.speed) {
      // 保持每条滚动弹幕已经走过的比例
      final now = _lastNow;
      for (final l in _live) {
        if (l.comment.mode == DanmakuMode.scroll) l.start = now - (now - l.start) / old.speed * c.speed;
      }
      changed = true;
    }
    if (old.area != c.area || old.fontSize != c.fontSize || old.showFixed != c.showFixed) {
      final laneH = c.fontSize * 1.32;
      final scrollLanes = (_size.height * c.area / laneH).floor().clamp(1, 60);
      final fixedLanes = (_size.height * 0.4 / laneH).floor().clamp(1, 30);
      _live.removeWhere((l) {
        final out = l.comment.mode == DanmakuMode.scroll
            ? l.lane >= scrollLanes
            : (!c.showFixed || l.lane >= fixedLanes);
        if (out) l.dispose();
        return out;
      });
      changed = true;
    }
    if (changed) _repaint.tick();
  }

  void _syncTicker() {
    final want = widget.comments.isNotEmpty;
    if (want && !_ticker.isActive) {
      // Ticker 重新从 0 计时：以当前位置为锚点重新开始
      _anchorPos = _moving ? _anchorPos + (_elapsed - _anchorAt).inMicroseconds / 1e6 * _rate : _anchorPos;
      _elapsed = _anchorAt = Duration.zero;
      _reset = true;
      _ticker.start();
    }
    if (!want && _ticker.isActive) {
      _ticker.stop();
      _clear();
      _repaint.tick();
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    _ticker.dispose();
    _clear();
    _repaint.dispose();
    super.dispose();
  }

  void _onState() {
    final s = widget.state.value;
    final reported = s.position.inMicroseconds / 1e6;
    final predicted = _moving ? _anchorPos + (_elapsed - _anchorAt).inMicroseconds / 1e6 * _rate : _anchorPos;
    final diff = reported - predicted;
    if (diff.abs() > 1.0) {
      // 拖动进度 / 切换资源：从新位置重新开始
      _anchorPos = reported;
      _reset = true;
    } else {
      // 小误差慢慢修正，避免弹幕一顿一顿
      _anchorPos = predicted + diff * 0.2;
    }
    _anchorAt = _elapsed;
    // 有的内核缓冲标志不可靠：进度在走就当作在播放
    _moving = s.playing && (!s.buffering || reported > _lastReported);
    _lastReported = reported;
    _rate = s.rate <= 0 ? 1 : s.rate;
  }

  void _clear() {
    for (final l in _live) {
      l.dispose();
    }
    _live.clear();
  }

  void _tick(Duration elapsed) {
    _elapsed = elapsed;
    if (_size.isEmpty) return;
    final now = _videoNow;
    if (now < _lastNow - 0.5) _reset = true;
    final comments = widget.comments;
    if (_reset) {
      _reset = false;
      _clear();
      _next = _lowerBound(comments, now - 0.3);
      _lastNow = now;
      _repaint.tick();
      return;
    }
    if (now == _lastNow) return; // 暂停：画面不变
    _lastNow = now;

    final c = widget.config;
    _live.removeWhere((l) {
      final life = l.comment.mode == DanmakuMode.scroll ? c.speed : DanmakuLayer.fixedSeconds;
      final dead = now - l.start > life;
      if (dead) l.dispose();
      return dead;
    });
    var emitted = 0;
    while (_next < comments.length && comments[_next].time <= now) {
      // 一帧最多出 12 条，避免瞬间刷屏；卡顿后积压的旧弹幕直接跳过
      if (emitted >= 12) break;
      final d = comments[_next++];
      if (now - d.time > 0.8) continue;
      if (d.mode != DanmakuMode.scroll && !c.showFixed) continue;
      if (_emit(d, now)) emitted++;
    }
    _repaint.tick();
  }

  static int _lowerBound(List<DanmakuComment> list, double t) {
    var lo = 0, hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (list[mid].time < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  double get _laneHeight => widget.config.fontSize * 1.32;

  bool _emit(DanmakuComment d, double now) {
    final c = widget.config;
    final (fill, stroke) = _paint(d);
    final w = fill.width;
    final laneH = _laneHeight;
    int? lane;
    if (d.mode == DanmakuMode.scroll) {
      final lanes = (_size.height * c.area / laneH).floor().clamp(1, 60);
      final last = List<_Live?>.filled(lanes, null);
      for (final l in _live) {
        if (l.comment.mode == DanmakuMode.scroll && l.lane < lanes) {
          final cur = last[l.lane];
          if (cur == null || l.start > cur.start) last[l.lane] = l;
        }
      }
      for (var i = 0; i < lanes; i++) {
        if (_fits(last[i], w, now)) {
          lane = i;
          break;
        }
      }
    } else {
      final lanes = (_size.height * 0.4 / laneH).floor().clamp(1, 30);
      final used = {
        for (final l in _live)
          if (l.comment.mode == d.mode) l.lane,
      };
      for (var i = 0; i < lanes; i++) {
        if (!used.contains(i)) {
          lane = i;
          break;
        }
      }
    }
    if (lane == null) {
      // 没有空位：丢掉这条，不叠在一起
      fill.dispose();
      stroke.dispose();
      return false;
    }
    _live.add(_Live(d, now, lane, fill, stroke));
    return true;
  }

  /// 新弹幕放进这一行会不会追上前一条（滚动速度 = (屏宽 + 自身宽度) / 时长，长的走得快）
  bool _fits(_Live? last, double w, double now) {
    if (last == null) return true;
    const gap = 28.0;
    final width = _size.width, dur = widget.config.speed;
    double tail(double t) => width - (t - last.start) / dur * (width + last.width) + last.width;
    double head(double t) => width - (t - now) / dur * (width + w);
    if (tail(now) + gap > head(now)) return false;
    final end = last.start + dur;
    return end <= now || head(end) >= tail(end) + gap;
  }

  (TextPainter, TextPainter) _paint(DanmakuComment d) {
    final c = widget.config;
    final color = Color(0xFF000000 | d.color).withValues(alpha: c.opacity);
    final dark = Color(0xFF000000 | d.color).computeLuminance() < 0.12;
    final base = TextStyle(
      fontSize: c.fontSize,
      fontWeight: FontWeight.w600,
      height: 1.2,
      letterSpacing: 0.5,
      fontFamilyFallback: const ['Microsoft YaHei', 'PingFang SC', 'Noto Sans CJK SC', 'sans-serif'],
    );
    final fill = TextPainter(
      text: TextSpan(
        text: d.text,
        style: base.copyWith(color: color),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final stroke = TextPainter(
      text: TextSpan(
        text: d.text,
        style: base.copyWith(
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = (c.fontSize / 11).clamp(2.0, 5.0)
            ..strokeJoin = StrokeJoin.round
            ..color = (dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000)).withValues(alpha: c.opacity * 0.75),
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return (fill, stroke);
  }

  Offset _offsetOf(_Live l, Size size) {
    final laneH = _laneHeight;
    const top = 16.0;
    return switch (l.comment.mode) {
      DanmakuMode.scroll => Offset(
        size.width - (_lastNow - l.start) / widget.config.speed * (size.width + l.width),
        top + l.lane * laneH,
      ),
      DanmakuMode.top => Offset((size.width - l.width) / 2, top + l.lane * laneH),
      DanmakuMode.bottom => Offset((size.width - l.width) / 2, size.height * 0.9 - (l.lane + 1) * laneH),
    };
  }

  /// 测试用：当前屏幕上每条弹幕的位置
  @visibleForTesting
  List<(String, Rect)> get debugRects => [
    for (final l in _live) (l.comment.text, _offsetOf(l, _size) & Size(l.width, l.fill.height)),
  ];

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: LayoutBuilder(
          builder: (context, constraints) {
            _size = constraints.biggest;
            return CustomPaint(size: constraints.biggest, painter: _DanmakuPainter(this));
          },
        ),
      ),
    );
  }
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter(this.s) : super(repaint: s._repaint);

  final DanmakuLayerState s;

  @override
  void paint(Canvas canvas, Size size) {
    for (final l in s._live) {
      final o = s._offsetOf(l, size);
      l.stroke.paint(canvas, o);
      l.fill.paint(canvas, o);
    }
  }

  @override
  bool shouldRepaint(_DanmakuPainter old) => !identical(old.s, s);
}

class _Repaint extends ChangeNotifier {
  void tick() => notifyListeners();
}
