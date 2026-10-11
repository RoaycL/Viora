import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/core/net/image_request_pool.dart';

void main() {
  test('图片并发有界，前台任务先于待处理预热，失败释放槽位', () async {
    final pool = ImageRequestPool(2);
    final release = Completer<void>();
    final started = <String>[];
    Future<void> task(String id) async {
      started.add(id);
      if (id == 'a' || id == 'b') await release.future;
      if (id == 'visible') throw StateError('unavailable');
    }

    final a = pool.run('a', () => task('a'));
    final b = pool.run('b', () => task('b'));
    final background = pool.run('background', () => task('background'), priority: ImageRequestPriority.prefetch);
    final visible = pool.run('visible', () => task('visible'), priority: ImageRequestPriority.visible);
    final failure = expectLater(visible, throwsStateError);
    expect(pool.active, 2);
    expect(pool.queued, 2);
    expect(started, ['a', 'b']);
    release.complete();
    await Future.wait([a, b, background, failure]);
    await Future<void>.delayed(Duration.zero);
    expect(started, ['a', 'b', 'visible', 'background']);
    expect(pool.active, 0);
    expect(pool.queued, 0);
  });

  test('预热进入视口后可以提升队列优先级，同优先级保持顺序', () async {
    final pool = ImageRequestPool(1);
    final release = Completer<void>();
    final first = pool.run('active', () => release.future);
    final started = <String>[];
    final a = pool.run('a', () async => started.add('a'));
    final b = pool.run('b', () async => started.add('b'), priority: ImageRequestPriority.prefetch);
    pool.promote('b', ImageRequestPriority.visible);
    release.complete();
    await Future.wait([first, a, b]);
    expect(started, ['b', 'a']);
  });
}
