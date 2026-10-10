import 'package:flutter_test/flutter_test.dart';
import 'package:viora/features/update/app_version.dart';
import 'package:viora/features/update/update_source.dart';

void main() {
  group('AppVersion', () {
    test('解析标签与构建号', () {
      expect(AppVersion.tryParse('v0.1.2'), const AppVersion(0, 1, 2));
      expect(AppVersion.tryParse('0.1.2+7'), const AppVersion(0, 1, 2, 7));
      expect(AppVersion.tryParse('nightly'), isNull);
    });

    test('比较大小', () {
      final v = AppVersion.tryParse;
      expect(v('0.1.1')! > v('0.1.0+9')!, isTrue);
      expect(v('0.2.0')! > v('0.10.0')!, isFalse);
      expect(v('1.0.0+2')! > v('1.0.0+1')!, isTrue);
      expect(v('v0.1.0')! > v('0.1.0+0')!, isFalse);
    });
  });

  test('按平台识别安装包', () {
    expect(matchesPlatformAsset('Viora-0.1.0-android.apk', UpdatePlatform.android), isTrue);
    expect(matchesPlatformAsset('Viora-0.1.0-windows-setup.exe', UpdatePlatform.windows), isTrue);
    expect(matchesPlatformAsset('Viora-0.1.0-windows-portable.zip', UpdatePlatform.windows), isFalse);
    expect(matchesPlatformAsset('latest.json', UpdatePlatform.android), isFalse);
  });
}
