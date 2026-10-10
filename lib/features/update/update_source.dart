import 'dart:convert';
import 'dart:io';

import 'app_version.dart';

enum UpdatePlatform {
  android,
  windows;

  static UpdatePlatform? get current => Platform.isAndroid
      ? android
      : Platform.isWindows
      ? windows
      : null;
}

/// 一次可用更新：版本号、说明，以及当前平台的安装包。
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.label,
    required this.notes,
    required this.downloadUrl,
    this.size,
    this.sha256,
    this.publishedAt,
  });

  final AppVersion version;

  /// 展示用的版本名（如 `v0.1.1`）
  final String label;
  final String notes;
  final Uri downloadUrl;
  final int? size;

  /// 小写十六进制；为空时不做校验
  final String? sha256;
  final DateTime? publishedAt;
}

abstract class UpdateSource {
  /// 返回该来源上最新版本（不判断是否比当前版本新）；没有可用包时返回 null。
  Future<UpdateInfo?> latest(UpdatePlatform platform);

  String get description;
}

/// 安装包命名约定（与 .github/workflows/release.yml 保持一致）：
/// - Android：`Viora-<版本>-android.apk`
/// - Windows：`Viora-<版本>-windows-setup.exe`
bool matchesPlatformAsset(String name, UpdatePlatform platform) {
  final n = name.toLowerCase();
  return switch (platform) {
    UpdatePlatform.android => n.endsWith('.apk'),
    UpdatePlatform.windows => n.endsWith('.exe') && n.contains('setup'),
  };
}

/// GitHub Releases（包含预发布版本）。仓库需要是公开的，客户端才能匿名访问。
class GitHubReleasesSource implements UpdateSource {
  GitHubReleasesSource(this.owner, this.repo, {required this.userAgent});

  final String owner;
  final String repo;
  final String userAgent;

  @override
  String get description => 'GitHub Releases · $owner/$repo';

  @override
  Future<UpdateInfo?> latest(UpdatePlatform platform) async {
    final json = await getJson(
      Uri.https('api.github.com', '/repos/$owner/$repo/releases', {'per_page': '20'}),
      userAgent: userAgent,
      headers: {'Accept': 'application/vnd.github+json'},
    );
    UpdateInfo? best;
    for (final release in (json as List).cast<Map<String, dynamic>>()) {
      if (release['draft'] == true) continue;
      final tag = release['tag_name'] as String? ?? '';
      final version = AppVersion.tryParse(tag);
      if (version == null) continue;
      if (best != null && !(version > best.version)) continue;
      final assets = (release['assets'] as List? ?? const []).cast<Map<String, dynamic>>();
      final asset = assets.where((a) => matchesPlatformAsset(a['name'] as String? ?? '', platform)).firstOrNull;
      if (asset == null) continue;
      final digest = asset['digest'] as String?;
      best = UpdateInfo(
        version: version,
        label: tag,
        notes: (release['body'] as String? ?? '').trim(),
        downloadUrl: Uri.parse(asset['browser_download_url'] as String),
        size: asset['size'] as int?,
        sha256: digest != null && digest.startsWith('sha256:') ? digest.substring(7).toLowerCase() : null,
        publishedAt: DateTime.tryParse(release['published_at'] as String? ?? ''),
      );
    }
    return best;
  }
}

/// 自建清单：一个 JSON 文件（CI 也会生成并上传到每个 Release，名为 latest.json）。
///
/// ```json
/// {
///   "version": "0.1.1",
///   "notes": "更新说明",
///   "published_at": "2026-10-10T08:00:00Z",
///   "assets": {
///     "android": {"url": "https://.../Viora-0.1.1-android.apk", "sha256": "...", "size": 123},
///     "windows": {"url": "https://.../Viora-0.1.1-windows-setup.exe", "sha256": "...", "size": 456}
///   }
/// }
/// ```
class ManifestSource implements UpdateSource {
  ManifestSource(this.url, {required this.userAgent});

  final Uri url;
  final String userAgent;

  @override
  String get description => '自定义地址 · ${url.host}';

  @override
  Future<UpdateInfo?> latest(UpdatePlatform platform) async {
    final json = await getJson(url, userAgent: userAgent) as Map<String, dynamic>;
    final version = AppVersion.tryParse(json['version'] as String? ?? '');
    final asset = (json['assets'] as Map<String, dynamic>?)?[platform.name] as Map<String, dynamic>?;
    if (version == null || asset == null) return null;
    return UpdateInfo(
      version: version,
      label: 'v${json['version']}',
      notes: (json['notes'] as String? ?? '').trim(),
      // 允许清单里写相对地址
      downloadUrl: url.resolve(asset['url'] as String),
      size: asset['size'] as int?,
      sha256: (asset['sha256'] as String?)?.toLowerCase(),
      publishedAt: DateTime.tryParse(json['published_at'] as String? ?? ''),
    );
  }
}

Future<Object?> getJson(Uri url, {required String userAgent, Map<String, String> headers = const {}}) async {
  final client = HttpClient()
    ..userAgent = userAgent
    ..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(url);
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(const Duration(seconds: 20));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw HttpException(
        response.statusCode == 404 ? '找不到更新信息（404），仓库可能是私有的' : 'HTTP ${response.statusCode}',
        uri: url,
      );
    }
    return jsonDecode(body);
  } finally {
    client.close(force: true);
  }
}
