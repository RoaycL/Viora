import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/data/tmdb/tmdb_disk_cache.dart';

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('viora-tmdb');
    TmdbDiskCache.directoryForTest = dir;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('reads back what was written, one file per key', () async {
    await TmdbDiskCache.write('viora.tmdb./movie/1', '{"a":1}');
    await TmdbDiskCache.write('viora.tmdb./movie/2', '{"b":2}');
    expect(await TmdbDiskCache.read('viora.tmdb./movie/1'), '{"a":1}');
    expect(await TmdbDiskCache.read('viora.tmdb./movie/3'), isNull);
    expect(dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')), hasLength(2));
  });

  test('prune deletes the oldest files when over the limit', () async {
    final big = 'x' * (TmdbDiskCache.maxBytes ~/ 4);
    for (var i = 0; i < 6; i++) {
      await TmdbDiskCache.write('k$i', big);
      File('${dir.path}/${dir.listSync().length}').existsSync();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await TmdbDiskCache.prune();
    final left = dir.listSync().whereType<File>().fold<int>(0, (s, f) => s + f.lengthSync());
    expect(left, lessThanOrEqualTo(TmdbDiskCache.maxBytes));
    expect(await TmdbDiskCache.read('k5'), isNotNull);
  });

  test('legacy TMDB entries in SharedPreferences are dropped in one go, other settings kept', () async {
    SharedPreferences.setMockInitialValues({
      'viora.tmdb./trending/all/day?language=zh-CN': '{"t":1,"d":{}}',
      'viora.tmdb./movie/550?language=zh-CN': '{"t":1,"d":{}}',
      'viora.playHistory.v1': '{}',
    });
    await TmdbDiskCache.dropLegacyPreferences();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), {'viora.playHistory.v1'});
  });
}
