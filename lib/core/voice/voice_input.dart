import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 语音输入（安卓 / 电视）：拉起系统的语音识别界面，返回识别出的文字。
/// 没有语音识别（部分国产盒子、Windows）时 [available] 为 false
class VoiceInput {
  VoiceInput._();

  static const _channel = MethodChannel('viora/voice');
  static Future<bool>? _available;

  static Future<bool> available() => _available ??= () async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      return false;
    }
  }();

  /// 识别出的文字；取消或没听清时返回 null
  static Future<String?> recognize({String? prompt}) async {
    try {
      final text = await _channel.invokeMethod<String>('recognize', {'prompt': ?prompt});
      final t = text?.trim();
      return t == null || t.isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static void debugReset() => _available = null;
}
