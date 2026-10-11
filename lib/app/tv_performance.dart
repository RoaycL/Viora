import 'package:flutter/foundation.dart';

import 'platform_profile.dart';

/// Development-only control build for measuring this batch on the same device.
abstract final class TvPerformance {
  static bool get baseline =>
      PlatformProfile.isTv && !kReleaseMode && const bool.fromEnvironment('VIORA_TV_PERF_BASELINE');
  static bool get enabled => PlatformProfile.isTv && !baseline;
}
