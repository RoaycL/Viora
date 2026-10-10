import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/player/preload.dart';

void main() {
  test('播放缓存设置：默认值与保存 / 读取', () {
    const d = PlaybackConfig();
    expect(d.warmMb, 2);
    expect(d.bufferMb, 256);
    expect(d.clearCacheOnExit, isTrue);

    final c = PlaybackConfig.fromJson(
      const PlaybackConfig(warmMb: 32, bufferMb: 1024, clearCacheOnExit: false).toJson(),
    );
    expect(c.warmMb, 32);
    expect(c.bufferMb, 1024);
    expect(c.clearCacheOnExit, isFalse);
    // 旧版本保存的配置没有这些字段
    final old = PlaybackConfig.fromJson(const {'userAgent': ''});
    expect(old.bufferMb, 256);
  });

  test('预热量按比例分给片头 / 续播位置 / 片尾', () {
    PlaybackPreloader.warmBytes = 32 * 1024 * 1024;
    expect(PlaybackPreloader.headBytes + PlaybackPreloader.resumeBytes + PlaybackPreloader.tailBytes, 32 * 1024 * 1024);
    PlaybackPreloader.warmBytes = 2 * 1024 * 1024;
    expect(PlaybackPreloader.tailBytes, greaterThanOrEqualTo(256 * 1024));
  });
}
