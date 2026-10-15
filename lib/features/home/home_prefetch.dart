import 'dart:async';

/// 预取任务独立于卡片挂载；当前需要的任务排在前面，替换队列不会继续启动旧任务。
/// 已开始的任务允许完成并进入缓存；失败只尝试一次，交由可见行显式重试。
class HomePrefetchQueue<K> {
  HomePrefetchQueue({required this.load, required this.concurrency}) : assert(concurrency > 0);

  final Future<void> Function(K key) load;
  final int concurrency;
  final _attempted = <K>{};
  final _running = <K>{};
  List<K> _pending = [];
  bool _disposed = false;

  void schedule(Iterable<K> keys) {
    if (_disposed) return;
    _pending = keys.toSet().where((key) => !_attempted.contains(key)).toList();
    _drain();
  }

  void _drain() {
    while (!_disposed && _running.length < concurrency && _pending.isNotEmpty) {
      final key = _pending.removeAt(0);
      _attempted.add(key);
      _running.add(key);
      unawaited(_run(key));
    }
  }

  Future<void> _run(K key) async {
    try {
      await load(key);
    } catch (_) {
      // 预取不弹错误、不循环重试；provider 自身仍保存错误，行内可重试。
    } finally {
      _running.remove(key);
      _drain();
    }
  }

  void dispose() {
    _disposed = true;
    _pending.clear();
  }
}
