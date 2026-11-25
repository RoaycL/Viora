import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora/player/mpv_engine.dart';

void main() {
  group('MpvEngine.textureSizeFor', () {
    test('4K 片源在 1080p 屏幕上按屏幕分辨率输出', () {
      expect(MpvEngine.textureSizeFor(3840, 2160, const Size(1920, 1080)), (1920, 1080));
    });

    test('宽银幕片源按「填满」需要的大小缩小，保持比例', () {
      // 3840×1600 → 高度铺满 1080：2592×1080
      expect(MpvEngine.textureSizeFor(3840, 1600, const Size(1920, 1080)), (2592, 1080));
    });

    test('2K 屏幕看 4K', () {
      expect(MpvEngine.textureSizeFor(3840, 2160, const Size(2560, 1440)), (2560, 1440));
    });

    test('片源不比屏幕大时不限制', () {
      expect(MpvEngine.textureSizeFor(1920, 1080, const Size(1920, 1080)), isNull);
      expect(MpvEngine.textureSizeFor(3840, 2160, const Size(3840, 2160)), isNull);
      expect(MpvEngine.textureSizeFor(1280, 720, const Size(1920, 1080)), isNull);
    });

    test('竖屏片源（已按旋转换成竖的宽高）保持竖的比例', () {
      // 3840×2160 旋转 90° → 2160×3840；在 1920×1080 屏幕上按填满：1920×3414
      final r = MpvEngine.textureSizeFor(2160, 3840, const Size(1920, 1080))!;
      expect(r.$1 < r.$2, isTrue);
      expect(r.$1, 1920);
    });

    test('屏幕大小未知时不限制', () {
      expect(MpvEngine.textureSizeFor(3840, 2160, Size.zero), isNull);
    });

    test('尺寸取偶数', () {
      final r = MpvEngine.textureSizeFor(3840, 2076, const Size(1366, 768))!;
      expect(r.$1.isEven && r.$2.isEven, isTrue);
      expect(r.$2, greaterThanOrEqualTo(768));
    });
  });
}
