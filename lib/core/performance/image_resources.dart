import 'package:flutter/widgets.dart';

import '../../app/tv_performance.dart';
import '../../ui/widgets/cached_image.dart';

/// ImageCache bounds retained decoded images, not all process/native memory.
class ImageResources with WidgetsBindingObserver {
  static final instance = ImageResources();
  bool _installed = false;

  void install() {
    if (_installed) return;
    _installed = true;
    CachedNetImage.configure(tv: TvPerformance.enabled);
    if (TvPerformance.enabled) {
      PaintingBinding.instance.imageCache
        ..maximumSize = 160
        ..maximumSizeBytes = 64 * 1024 * 1024;
    }
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didHaveMemoryPressure() {
    // Active widgets keep their images; release unused decoded cache entries.
    PaintingBinding.instance.imageCache.clear();
  }
}
