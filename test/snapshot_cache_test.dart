import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/cache/snapshot_cache.dart';
import 'package:viora/data/media/media_models.dart';

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('viora-snap');
    SnapshotCache.resetForTest();
    SnapshotCache.directoryForTest = dir;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('MediaItem 快照字段完整往返', () {
    final it = MediaItem(
      serverId: 's',
      id: '1',
      kind: MediaKind.episode,
      name: '第一集',
      seriesId: 'x',
      seriesName: '繁花',
      seasonNumber: 1,
      episodeNumber: 3,
      position: const Duration(minutes: 12),
      runtime: const Duration(minutes: 45),
      primary: const ImageRef('1', ImageKind.primary, tag: 't'),
      lastPlayed: DateTime(2026, 10, 1),
      played: true,
    );
    final back = MediaItem.decodeList(MediaItem.encodeList([it])).single;
    expect(back.seriesName, '繁花');
    expect(back.episodeLabel, 'S1E3');
    expect(back.position, const Duration(minutes: 12));
    expect(back.progress, it.progress);
    expect(back.primary?.tag, 't');
    expect(back.lastPlayed, DateTime(2026, 10, 1));
    expect(back.played, isTrue);
  });

  test('先返回上次的快照，随后自动刷新成最新数据', () async {
    var fetches = 0;
    var latest = [1, 2];
    final p = FutureProvider<List<int>>(
      (ref) => snapshotFirst(
        ref,
        'nums',
        fetch: () async {
          fetches++;
          return latest;
        },
        encode: (v) => v,
        decode: (j) => (j as List).cast<int>(),
      ),
    );

    // 第一次运行：没有快照，直接拉取并保存
    var c = ProviderContainer();
    expect(await c.read(p.future), [1, 2]);
    expect(fetches, 1);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    c.dispose();

    // 「重新打开应用」：先拿到快照，后台刷新后变成新数据
    SnapshotCache.resetForTest();
    SnapshotCache.directoryForTest = dir;
    latest = [3];
    c = ProviderContainer();
    final sub = c.listen(p, (_, _) {});
    expect(await c.read(p.future), [1, 2]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sub.read().value, [3]);
    expect(fetches, 2);
    c.dispose();
  });
}
