import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/features/player/slider_adjuster.dart';
import 'package:viora/player/mpv_engine.dart';
import 'package:viora/player/sleep_timer.dart';

void main() {
  tearDown(SleepTimer.clear);

  group('SleepTimer', () {
    test('按分钟定时：剩余时间向上取整到分钟', () {
      final now = DateTime(2026, 11, 25, 22);
      SleepTimer.setMinutes(30, now: now);
      expect(SleepTimer.active, isTrue);
      expect(SleepTimer.remaining(now: now), const Duration(minutes: 30));
      expect(SleepTimer.label(now: now.add(const Duration(minutes: 10, seconds: 30))), '剩 20 分钟');
      expect(SleepTimer.remaining(now: now.add(const Duration(hours: 1))), Duration.zero);
    });

    test('本集播完和按分钟互斥', () {
      SleepTimer.setMinutes(15);
      SleepTimer.setEndOfItem();
      expect(SleepTimer.deadline, isNull);
      expect(SleepTimer.label(), '本集播完');
      SleepTimer.setMinutes(15);
      expect(SleepTimer.endOfItem, isFalse);
    });

    test('关闭', () {
      SleepTimer.setEndOfItem();
      SleepTimer.clear();
      expect(SleepTimer.active, isFalse);
      expect(SleepTimer.label(), '关');
    });
  });

  test('音画同步的显示', () {
    expect(SliderSpec.audioDelayLabel(0), '不偏移');
    expect(SliderSpec.audioDelayLabel(0.12), '声音推后 120 毫秒');
    expect(SliderSpec.audioDelayLabel(-0.25), '声音提前 250 毫秒');
    expect(SliderSpec.audioDelay.snap(0.123), closeTo(0.1, 1e-9));
  });

  test('音画同步按设备保存，读取时限制范围', () {
    final c = const PlaybackConfig().copyWith(audioDelayMs: -150);
    expect(PlaybackConfig.fromJson(c.toJson()).audioDelayMs, -150);
    expect(
      PlaybackConfig.fromJson({...c.toJson(), 'audioDelayMs': 99999}).audioDelayMs,
      PlaybackConfig.audioDelayLimitMs,
    );
    expect(PlaybackConfig.fromJson(const {}).audioDelayMs, 0);
  });

  test('mpv 解码方式', () {
    expect(MpvEngine.mpvDecoderLabel('no'), '软解（CPU）');
    expect(MpvEngine.mpvDecoderLabel('d3d11va'), '硬解 · d3d11va');
  });
}
