import 'package:flutter_test/flutter_test.dart';
import 'package:viora/core/performance/frame_stats.dart';

void main() {
  test('帧统计分别报告 UI/Raster 耗时，按屏幕预算计慢帧且每窗口重置', () {
    final stats = FrameStatsWindow();
    expect(stats.takeSummary(), isNull);
    for (var i = 0; i < 19; i++) {
      stats.add(
        const Duration(milliseconds: 4),
        const Duration(milliseconds: 6),
        const Duration(milliseconds: 12),
        budgetUs: 16666,
      );
    }
    stats.add(
      const Duration(milliseconds: 18),
      const Duration(milliseconds: 9),
      const Duration(milliseconds: 29),
      budgetUs: 16666,
    );
    final summary = stats.takeSummary()!;
    expect(summary, contains('frames=20 slow=1'));
    expect(summary, contains('build_p95_ms=4.00 build_max_ms=18.00'));
    expect(summary, contains('raster_p95_ms=6.00 raster_max_ms=9.00'));
    expect(stats.takeSummary(), isNull);
    stats.add(
      const Duration(milliseconds: 9),
      const Duration(milliseconds: 3),
      const Duration(milliseconds: 12),
      budgetUs: 8333,
    );
    expect(stats.takeSummary(), contains('frames=1 slow=1 budget_ms=8.33'));
  });

  test('超出样本上限仍累计慢帧与最大耗时', () {
    final stats = FrameStatsWindow();
    for (var i = 0; i < FrameStatsWindow.maxSamples + 1; i++) {
      stats.add(Duration(milliseconds: i), Duration.zero, Duration(milliseconds: i), budgetUs: 16666);
    }
    final summary = stats.takeSummary()!;
    expect(summary, contains('frames=1025'));
    expect(summary, contains('build_max_ms=1024.00'));
  });
}
