import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/features/home/home_prefetch.dart';

void main() {
  test('后台任务有并发上限，重复调度同一行不重复请求', () async {
    final gates = {for (var i = 1; i <= 4; i++) i: Completer<void>()};
    final started = <int>[];
    var active = 0, peak = 0;
    final queue = HomePrefetchQueue<int>(
      concurrency: 2,
      load: (key) async {
        started.add(key);
        active++;
        if (active > peak) peak = active;
        await gates[key]!.future;
        active--;
      },
    );
    queue.schedule([1, 2, 3, 4]);
    queue.schedule([1, 1, 2, 3, 4]);
    expect(started, [1, 2]);
    gates[1]!.complete();
    await pumpEventQueue();
    expect(started, [1, 2, 3]);
    gates[2]!.complete();
    await pumpEventQueue();
    expect(started, [1, 2, 3, 4]);
    gates[3]!.complete();
    gates[4]!.complete();
    await pumpEventQueue();
    queue.schedule([1, 2, 3, 4]);
    expect(started, [1, 2, 3, 4]);
    expect(peak, 2);
    queue.dispose();
  });

  test('快速滚动替换等待任务，旧方向的排队图片不再启动', () async {
    final gate = Completer<void>();
    final started = <int>[];
    final queue = HomePrefetchQueue<int>(
      concurrency: 1,
      load: (key) async {
        started.add(key);
        if (key == 1) await gate.future;
      },
    );
    queue.schedule([1, 2, 3]);
    queue.schedule([9, 3]);
    gate.complete();
    await pumpEventQueue();
    expect(started, [1, 9, 3]);
    queue.dispose();
  });

  test('一次失败不触发预取重试循环，也不阻塞后续行', () async {
    final started = <int>[];
    final queue = HomePrefetchQueue<int>(
      concurrency: 1,
      load: (key) async {
        started.add(key);
        if (key == 1) throw StateError('offline');
      },
    );
    queue.schedule([1, 2]);
    await pumpEventQueue();
    queue.schedule([1, 2, 3]);
    await pumpEventQueue();
    expect(started, [1, 2, 3]);
    queue.dispose();
  });

  test('页面销毁后正在进行的任务可以结束，剩余任务停止启动', () async {
    final gate = Completer<void>();
    final started = <int>[];
    final queue = HomePrefetchQueue<int>(
      concurrency: 1,
      load: (key) async {
        started.add(key);
        await gate.future;
      },
    );
    queue.schedule([1, 2, 3]);
    queue.dispose();
    queue.schedule([9]);
    gate.complete();
    await pumpEventQueue();
    expect(started, [1]);
  });
}
