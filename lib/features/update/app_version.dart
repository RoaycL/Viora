/// 打包时注入的测试版序号（`beta1`、`beta2`…；正式版为空）。
/// 测试版不单独占版本号：pubspec 里是下一个正式版的版本号，测试版在它后面加 `-betaN`
const appPrerelease = String.fromEnvironment('VIORA_PRERELEASE');

/// 带测试版后缀的版本号（如 `0.17.6-beta1`），用于显示、UA、上报
String withPrerelease(String version) => appPrerelease.isEmpty ? version : '$version-$appPrerelease';

/// 语义化版本（`1.2.3` / `v1.2.3` / `1.2.3+45` / `1.2.3-beta2` / `1.2.3-beta2+45`），用于比较新旧版本。
///
/// 同一个版本号：测试版 < 正式版，beta1 < beta2（`0.17.6-beta1` < `0.17.6-beta2` < `0.17.6`）。
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, [this.build = 0, this.beta]);

  final int major;
  final int minor;
  final int patch;
  final int build;

  /// 测试版序号；null = 正式版
  final int? beta;

  bool get isBeta => beta != null;

  /// 整串匹配：认不出的后缀（`-rc1`、`-alpha1`）整个不认，免得被当成正式版
  static final _pattern = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-beta\.?(\d+))?(?:[-+.](\d+))?$');

  static AppVersion? tryParse(String raw) {
    final m = _pattern.firstMatch(raw.trim());
    if (m == null) return null;
    return AppVersion(
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
      int.tryParse(m[5] ?? '') ?? 0,
      int.tryParse(m[4] ?? ''),
    );
  }

  @override
  int compareTo(AppVersion other) {
    for (final d in [major - other.major, minor - other.minor, patch - other.patch]) {
      if (d != 0) return d.sign;
    }
    // 同一个版本号：正式版比它的测试版新，测试版按序号比
    if (beta != other.beta) {
      if (beta == null) return 1;
      if (other.beta == null) return -1;
      return (beta! - other.beta!).sign;
    }
    return (build - other.build).sign;
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, build, beta);

  @override
  String toString() => '$major.$minor.$patch${beta == null ? '' : '-beta$beta'}';
}
