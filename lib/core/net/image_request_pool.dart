import 'dart:async';

enum ImageRequestPriority { visible, normal, prefetch }

/// Limits total image downloads, independently of per-host connection limits.
/// Priority affects pending work only; active responses are never interrupted.
class ImageRequestPool {
  ImageRequestPool(this.limit) : assert(limit > 0);
  final int limit;
  int _active = 0;
  final _pending = <_ImageRequest>[];
  int get active => _active;
  int get queued => _pending.length;

  Future<T> run<T>(
    Object key,
    Future<T> Function() work, {
    ImageRequestPriority priority = ImageRequestPriority.normal,
  }) {
    final done = Completer<T>();
    _pending.add(
      _ImageRequest(key, priority, () async {
        try {
          done.complete(await work());
        } catch (e, s) {
          done.completeError(e, s);
        }
      }),
    );
    _drain();
    return done.future;
  }

  void promote(Object key, ImageRequestPriority priority) {
    for (final request in _pending) {
      if (request.key == key && priority.index < request.priority.index) request.priority = priority;
    }
  }

  void _drain() {
    while (_active < limit && _pending.isNotEmpty) {
      var next = 0;
      for (var i = 1; i < _pending.length; i++) {
        if (_pending[i].priority.index < _pending[next].priority.index) next = i;
      }
      final request = _pending.removeAt(next);
      _active++;
      unawaited(
        request.work().whenComplete(() {
          _active--;
          _drain();
        }),
      );
    }
  }
}

class _ImageRequest {
  _ImageRequest(this.key, this.priority, this.work);
  final Object key;
  ImageRequestPriority priority;
  final Future<void> Function() work;
}
