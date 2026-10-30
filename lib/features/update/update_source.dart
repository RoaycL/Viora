import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'app_version.dart';

enum UpdatePlatform {
  android,
  windows;

  static UpdatePlatform? get current => kIsWeb
      ? null
      : Platform.isAndroid
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
  /// [abi] 为 null 时取当前设备的架构（只对 Android 有意义）。
  Future<UpdateInfo?> latest(UpdatePlatform platform, {String? abi});

  String get description;
}

/// 当前进程的 Android CPU 架构（取自 Dart 运行时，如 `on "android_arm64"`）。
/// 64 位设备跑 32 位系统（不少电视盒子如此）时这里是 arm，正好对应能装的那个包；其他平台为 null。
String? currentAndroidAbi() {
  if (kIsWeb || !Platform.isAndroid) return null;
  return androidAbiOf(Platform.version);
}

String? androidAbiOf(String dartVersion) {
  if (dartVersion.contains('android_arm64')) return 'arm64-v8a';
  if (dartVersion.contains('android_arm')) return 'armeabi-v7a';
  if (dartVersion.contains('android_x64')) return 'x86_64';
  return null;
}

/// 安装包命名约定（与 .github/workflows/release.yml 保持一致）：
/// - Android：`Viora-<版本>-android-<ABI>.apk`（按架构拆分，体积小）和 `Viora-<版本>-android.apk`（通用包）
/// - Windows：`Viora-<版本>-windows-setup.exe`
bool matchesPlatformAsset(String name, UpdatePlatform platform) {
  final n = name.toLowerCase();
  return switch (platform) {
    UpdatePlatform.android => n.endsWith('.apk'),
    UpdatePlatform.windows => n.endsWith('.exe') && n.contains('setup'),
  };
}

/// 从一组安装包名里挑当前设备该装的：Android 优先本机架构的拆分包，没有就用通用包，
/// 绝不挑别的架构的拆分包（装不上）。
int? pickPlatformAsset(List<String> names, UpdatePlatform platform, {String? abi}) {
  int? fallback;
  for (var i = 0; i < names.length; i++) {
    final n = names[i].toLowerCase();
    if (!matchesPlatformAsset(n, platform)) continue;
    if (platform != UpdatePlatform.android) return i;
    if (abi != null && n.endsWith('-$abi.apk')) return i;
    if (!_androidAbis.any((a) => n.endsWith('-$a.apk'))) fallback ??= i;
  }
  return fallback;
}

const _androidAbis = ['arm64-v8a', 'armeabi-v7a', 'x86_64'];

/// latest.json 里拆分包的键名（`android-arm64-v8a`），通用包仍是 `android`
String manifestAssetKey(UpdatePlatform platform, String? abi) =>
    platform == UpdatePlatform.android && abi != null ? 'android-$abi' : platform.name;

/// GitHub Releases（包含预发布版本）。仓库需要是公开的，客户端才能匿名访问。
class GitHubReleasesSource implements UpdateSource {
  GitHubReleasesSource(this.owner, this.repo, {required this.userAgent, this.rewrite});

  final String owner;
  final String repo;
  final String userAgent;

  /// 改写请求地址（经反向代理访问 GitHub）
  final Uri Function(Uri)? rewrite;

  /// 项目主页
  Uri get homepage => Uri.https('github.com', '/$owner/$repo');

  @override
  String get description => 'GitHub Releases · $owner/$repo';

  @override
  Future<UpdateInfo?> latest(UpdatePlatform platform, {String? abi}) async {
    abi ??= currentAndroidAbi();
    final json = await getJson(
      Uri.https('api.github.com', '/repos/$owner/$repo/releases', {'per_page': '20'}),
      userAgent: userAgent,
      rewrite: rewrite,
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
      final index = pickPlatformAsset([for (final a in assets) a['name'] as String? ?? ''], platform, abi: abi);
      if (index == null) continue;
      final asset = assets[index];
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
///     "android-arm64-v8a": {"url": "https://.../Viora-0.1.1-android-arm64-v8a.apk", "sha256": "...", "size": 45},
///     "android-armeabi-v7a": {"url": "https://.../Viora-0.1.1-android-armeabi-v7a.apk", "sha256": "...", "size": 40},
///     "windows": {"url": "https://.../Viora-0.1.1-windows-setup.exe", "sha256": "...", "size": 456}
///   }
/// }
/// ```
/// Android 优先取本机架构的拆分包（可省略），没有就用通用的 `android`。
class ManifestSource implements UpdateSource {
  ManifestSource(this.url, {required this.userAgent, this.rewrite});

  final Uri url;
  final String userAgent;
  final Uri Function(Uri)? rewrite;

  @override
  String get description => '自定义地址 · ${url.host}';

  @override
  Future<UpdateInfo?> latest(UpdatePlatform platform, {String? abi}) async {
    abi ??= currentAndroidAbi();
    final json = await getJson(url, userAgent: userAgent, rewrite: rewrite) as Map<String, dynamic>;
    final version = AppVersion.tryParse(json['version'] as String? ?? '');
    final assets = json['assets'] as Map<String, dynamic>?;
    final asset = (assets?[manifestAssetKey(platform, abi)] ?? assets?[platform.name]) as Map<String, dynamic>?;
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

Future<Object?> getJson(
  Uri url, {
  required String userAgent,
  Map<String, String> headers = const {},
  Uri Function(Uri)? rewrite,
}) async {
  final client = HttpClient()
    ..userAgent = userAgent
    ..connectionTimeout = const Duration(seconds: 10);
  try {
    final response = await openFollowingRedirects(client, url, headers: headers, rewrite: rewrite);
    final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
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

/// GET 并手动跟随跳转：每一跳都经 [rewrite] 改写。
/// GitHub 的安装包下载会跳到 objects.githubusercontent.com，经反向代理时这一跳也要走代理
Future<HttpClientResponse> openFollowingRedirects(
  HttpClient client,
  Uri url, {
  Map<String, String> headers = const {},
  Uri Function(Uri)? rewrite,
}) async {
  var next = url;
  for (var i = 0; i < 6; i++) {
    final request = await client.getUrl(rewrite == null ? next : rewrite(next));
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(const Duration(seconds: 20));
    final location = response.headers.value(HttpHeaders.locationHeader);
    if (!response.isRedirect || location == null) return response;
    await response.drain<void>();
    next = next.resolve(location);
  }
  throw HttpException('跳转次数过多', uri: url);
}
