import 'package:flutter_test/flutter_test.dart';
import 'package:viora/player/preload.dart';

void main() {
  test('播放信息缓存：maxAge 比缓存年龄小时当作没有，但不删掉', () async {
    const PlaybackInfoResult info = (sources: [], playSessionId: 'p');
    PlaybackPreloader.put('s', 'max-age', info, scope: 'a');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(PlaybackPreloader.cached('s', 'max-age', scope: 'a'), isNotNull);
    expect(PlaybackPreloader.cached('s', 'max-age', scope: 'a', maxAge: const Duration(milliseconds: 1)), isNull);
    expect(PlaybackPreloader.cached('s', 'max-age', scope: 'a', maxAge: const Duration(minutes: 1)), isNotNull);
    expect(PlaybackPreloader.cached('s', 'max-age', scope: 'a'), isNotNull);
  });
}
