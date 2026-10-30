import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/cache/snapshot_cache.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('snapshot_read');
    SnapshotCache.resetForTest();
    SnapshotCache.directoryForTest = dir;
  });
  tearDown(() async {
    SnapshotCache.resetForTest();
    await dir.delete(recursive: true);
  });

  test('大快照在后台解析，结果与小快照一致；损坏的文件当作没有快照', () async {
    final small = {
      'version': 2,
      'data': ['a', 'b'],
    };
    final large = {
      'version': 2,
      'data': [
        for (var i = 0; i < 5000; i++) {'id': '$i', 'name': '作品 $i 的名字比较长'},
      ],
    };
    await SnapshotCache.write('small', small);
    await SnapshotCache.write('large', large);
    expect(await File('${dir.path}/large.json').length(), greaterThan(64 * 1024));
    expect(await SnapshotCache.read('small'), small);
    expect(await SnapshotCache.read('large'), large);
    expect(await SnapshotCache.read('missing'), isNull);
    await File('${dir.path}/broken.json').writeAsString('{"version": 2, "data": [${'1,' * 40000}');
    expect(await SnapshotCache.read('broken'), isNull);
  });
}
