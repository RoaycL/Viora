/// 语义化版本（`1.2.3` / `v1.2.3` / `1.2.3+45`），用于比较新旧版本。
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, [this.build = 0]);

  final int major;
  final int minor;
  final int patch;
  final int build;

  static AppVersion? tryParse(String raw) {
    final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:[-+.](\d+))?').firstMatch(raw.trim());
    if (m == null) return null;
    return AppVersion(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), int.tryParse(m[4] ?? '') ?? 0);
  }

  @override
  int compareTo(AppVersion other) {
    for (final d in [major - other.major, minor - other.minor, patch - other.patch, build - other.build]) {
      if (d != 0) return d.sign;
    }
    return 0;
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, build);

  @override
  String toString() => '$major.$minor.$patch';
}
