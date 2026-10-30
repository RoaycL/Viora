import 'app_log.dart';

/// 数据加载阶段耗时；只记录类型、匿名来源、数量，不记录查询词和连接凭据。
class LoadTrace {
  LoadTrace(this.operation) : _watch = Stopwatch()..start();

  final String operation;
  final Stopwatch _watch;
  static final _active = <String, int>{};
  static final _peak = <String, int>{};

  void event(String phase, {int? count, int? sources, int? cached, int? failed}) {
    AppLog.add(
      '[load] op=$operation phase=$phase ms=${_watch.elapsedMilliseconds}'
      '${count == null ? '' : ' items=$count'}'
      '${sources == null ? '' : ' sources=$sources'}'
      '${cached == null ? '' : ' cached=$cached'}'
      '${failed == null ? '' : ' failed=$failed'}',
    );
  }

  /// 超过这个耗时的请求才单独记一行（失败的总是记）。16 台服务器每次同步都逐条记录会把
  /// 闪退前的关键日志挤出 3000 行的缓冲区
  static const slowMs = 1500;

  static Future<T> request<T>(
    String operation,
    String source,
    Future<T> Function() action, {
    bool Function(T)? isSuccess,
  }) async {
    final watch = Stopwatch()..start();
    final active = _active.update(operation, (n) => n + 1, ifAbsent: () => 1);
    if (active > (_peak[operation] ?? 0)) _peak[operation] = active;
    var outcome = 'ok';
    try {
      final result = await action();
      if (isSuccess != null && !isSuccess(result)) outcome = 'failed';
      return result;
    } catch (_) {
      outcome = 'failed';
      rethrow;
    } finally {
      _active[operation] = _active[operation]! - 1;
      if (outcome != 'ok' || watch.elapsedMilliseconds >= slowMs) {
        AppLog.add(
          '[load] op=$operation phase=remote source=$source outcome=$outcome'
          ' ms=${watch.elapsedMilliseconds} active=${_active[operation]} peak=${_peak[operation]}',
        );
      }
    }
  }
}
