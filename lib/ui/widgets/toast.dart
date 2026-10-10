import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../app/theme.dart';
import '../glass/glass.dart';

final _toast = ValueNotifier<String?>(null);
Timer? _toastTimer;

/// 屏幕底部的轻提示（如"再按一次返回键退出"）。
void showToast(String message, {Duration duration = const Duration(seconds: 2)}) {
  _toast.value = message;
  _toastTimer?.cancel();
  _toastTimer = Timer(duration, () => _toast.value = null);
}

class ToastOverlay extends StatelessWidget {
  const ToastOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder<String?>(
        valueListenable: _toast,
        builder: (context, message, _) => AnimatedOpacity(
          opacity: message == null ? 0 : 1,
          duration: VMotion.focus,
          child: Align(
            alignment: const Alignment(0, 0.86),
            child: message == null
                ? const SizedBox.shrink()
                : Glass(
                    radius: 999,
                    fill: const Color(0x8C14161E),
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    child: Text(message, style: VText.caption),
                  ),
          ),
        ),
      ),
    );
  }
}
