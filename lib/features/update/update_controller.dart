import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/config/config_store.dart';
import '../../data/net/request_composer.dart';
import 'app_version.dart';
import 'update_source.dart';

/// 默认更新源：本项目的 GitHub Releases。
const defaultUpdateOwner = 'RoaycL';
const defaultUpdateRepo = 'Viora';

/// 更新设置（持久化在 shared_preferences）。
class UpdateSettings {
  const UpdateSettings({this.autoCheck = true, this.manifestUrl, this.useProxy = false});

  final bool autoCheck;

  /// 非空时使用自定义清单地址，否则使用 GitHub Releases
  final String? manifestUrl;

  /// 检查和下载更新都经反向代理（「设置 → 接口与网络」的地址）。
  /// 关闭时也会在直连失败后自动改走代理再试一次
  final bool useProxy;

  static const _kAutoCheck = 'update.autoCheck';
  static const _kManifest = 'update.manifestUrl';
  static const _kProxy = 'update.useProxy';

  UpdateSettings copyWith({bool? autoCheck, String? manifestUrl, bool clearManifest = false, bool? useProxy}) =>
      UpdateSettings(
        autoCheck: autoCheck ?? this.autoCheck,
        manifestUrl: clearManifest ? null : (manifestUrl ?? this.manifestUrl),
        useProxy: useProxy ?? this.useProxy,
      );

  static Future<UpdateSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_kManifest);
    return UpdateSettings(
      autoCheck: prefs.getBool(_kAutoCheck) ?? true,
      manifestUrl: url == null || url.isEmpty ? null : url,
      useProxy: prefs.getBool(_kProxy) ?? false,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoCheck, autoCheck);
    await prefs.setString(_kManifest, manifestUrl ?? '');
    await prefs.setBool(_kProxy, useProxy);
  }
}

sealed class UpdateState {
  const UpdateState();
}

class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

class UpdateChecking extends UpdateState {
  const UpdateChecking();
}

class UpdateUpToDate extends UpdateState {
  const UpdateUpToDate();
}

class UpdateAvailable extends UpdateState {
  const UpdateAvailable(this.info);
  final UpdateInfo info;
}

class UpdateDownloading extends UpdateState {
  const UpdateDownloading(this.info, this.received, this.total);
  final UpdateInfo info;
  final int received;
  final int? total;
  double? get progress => total == null || total == 0 ? null : received / total!;
}

/// Android：系统安装界面已打开，或需要用户先授权"安装未知应用"。
class UpdateInstalling extends UpdateState {
  const UpdateInstalling(this.info, {this.needsPermission = false});
  final UpdateInfo info;
  final bool needsPermission;
}

class UpdateFailed extends UpdateState {
  const UpdateFailed(this.message, {this.info});
  final String message;
  final UpdateInfo? info;
}

class UpdateController extends Notifier<UpdateState> {
  static const _channel = MethodChannel('viora/update');

  PackageInfo? _package;
  UpdateSettings settings = const UpdateSettings();
  File? _downloaded;

  @override
  UpdateState build() => const UpdateIdle();

  Future<PackageInfo> get packageInfo async => _package ??= await PackageInfo.fromPlatform();

  Future<AppVersion> get currentVersion async {
    final p = await packageInfo;
    return AppVersion.tryParse('${p.version}+${p.buildNumber}') ?? const AppVersion(0, 0, 0);
  }

  /// 经反向代理改写地址；没填反代地址时为 null
  Uri Function(Uri)? get _proxyRewrite {
    final proxy = ref.read(configProvider).proxy;
    if (!proxy.enabled) return null;
    return (u) => proxify(u, proxy.baseUrl);
  }

  /// 这次检查 / 下载是否走反代：设置里打开了，或直连失败后的重试
  bool _viaProxy = false;

  Future<UpdateSource> _source({bool? viaProxy}) async {
    final p = await packageInfo;
    final ua = 'Viora/${p.version} (${Platform.operatingSystem})';
    final rewrite = (viaProxy ?? _viaProxy) ? _proxyRewrite : null;
    final manifest = settings.manifestUrl;
    if (manifest != null) return ManifestSource(Uri.parse(manifest), userAgent: ua, rewrite: rewrite);
    return GitHubReleasesSource(defaultUpdateOwner, defaultUpdateRepo, userAgent: ua, rewrite: rewrite);
  }

  /// 项目主页
  static final homepage = GitHubReleasesSource(defaultUpdateOwner, defaultUpdateRepo, userAgent: '').homepage;

  /// 是否填了反向代理地址（设置页据此决定能不能打开「经反向代理更新」）
  bool get proxyAvailable => ref.read(configProvider).proxy.enabled;

  Future<String> sourceDescription() async => (await _source()).description;

  Future<void> loadSettings() async => settings = await UpdateSettings.load();

  Future<void> saveSettings(UpdateSettings value) async {
    settings = value;
    await value.save();
  }

  /// 检查更新。返回可用更新（若有）。[silent] 时失败不进入错误状态（启动时自动检查用）。
  Future<UpdateInfo?> check({bool silent = false}) async {
    final platform = UpdatePlatform.current;
    if (platform == null) {
      if (!silent) state = const UpdateFailed('当前平台不支持应用内更新');
      return null;
    }
    if (state is UpdateDownloading) return null;
    state = const UpdateChecking();
    try {
      UpdateInfo? latest;
      _viaProxy = settings.useProxy && _proxyRewrite != null;
      try {
        latest = await (await _source()).latest(platform);
      } catch (e) {
        // 直连失败（电视连不上 GitHub 很常见）：填了反代地址就改走反代再试一次，下载也跟着走反代
        if (_viaProxy || _proxyRewrite == null) rethrow;
        debugPrint('update check direct failed, retry via proxy: $e');
        _viaProxy = true;
        latest = await (await _source()).latest(platform);
      }
      final current = await currentVersion;
      if (latest != null && latest.version > current) {
        state = UpdateAvailable(latest);
        return latest;
      }
      state = const UpdateUpToDate();
    } catch (e) {
      debugPrint('update check failed: $e');
      state = silent ? const UpdateIdle() : UpdateFailed(_describe(e));
    }
    return null;
  }

  /// 下载并安装。Windows 会启动安装程序并退出当前应用；Android 会打开系统安装界面。
  Future<void> downloadAndInstall(UpdateInfo info) async {
    try {
      final file = _downloaded != null && await _downloaded!.exists() ? _downloaded! : await _download(info);
      _downloaded = file;
      await _install(info, file);
    } catch (e) {
      state = UpdateFailed(_describe(e), info: info);
    }
  }

  Future<File> _download(UpdateInfo info) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}updates');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final name = info.downloadUrl.pathSegments.isEmpty ? 'viora-update' : info.downloadUrl.pathSegments.last;
    final file = File('${dir.path}${Platform.pathSeparator}$name');

    final p = await packageInfo;
    final client = HttpClient()
      ..userAgent = 'Viora/${p.version} (${Platform.operatingSystem})'
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final response = await openFollowingRedirects(
        client,
        info.downloadUrl,
        rewrite: _viaProxy ? _proxyRewrite : null,
      );
      if (response.statusCode != 200) throw HttpException('下载失败：HTTP ${response.statusCode}');
      final total = response.contentLength > 0 ? response.contentLength : info.size;
      final sink = file.openWrite();
      var received = 0;
      var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
      state = UpdateDownloading(info, 0, total);
      try {
        await for (final chunk in response.timeout(const Duration(seconds: 30))) {
          sink.add(chunk);
          received += chunk.length;
          final now = DateTime.now();
          if (now.difference(lastEmit) > const Duration(milliseconds: 150)) {
            lastEmit = now;
            state = UpdateDownloading(info, received, total);
          }
        }
      } finally {
        await sink.close();
      }
      state = UpdateDownloading(info, received, total);
    } finally {
      client.close(force: true);
    }

    final expected = info.sha256;
    if (expected != null) {
      final actual = (await sha256.bind(file.openRead()).first).toString();
      if (actual != expected) {
        await file.delete();
        throw const FileSystemException('安装包校验失败（SHA-256 不一致），请重试');
      }
    }
    return file;
  }

  Future<void> _install(UpdateInfo info, File file) async {
    if (Platform.isAndroid) {
      final result = await _channel.invokeMethod<String>('installApk', {'path': file.path});
      state = UpdateInstalling(info, needsPermission: result == 'needs_permission');
    } else if (Platform.isWindows) {
      state = UpdateInstalling(info);
      // Inno Setup 安装包：静默安装（显示进度），安装完成后自动重新打开 Viora。
      await Process.start(file.path, [
        '/SILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/CLOSEAPPLICATIONS',
      ], mode: ProcessStartMode.detached);
      exit(0);
    } else {
      throw UnsupportedError('当前平台不支持应用内更新');
    }
  }

  String _describe(Object e) => switch (e) {
    HttpException(:final message) => message,
    SocketException() => '网络连接失败，请检查网络后重试',
    TimeoutException() => '连接超时，请稍后重试',
    FileSystemException(:final message) => message,
    PlatformException(:final message) => message ?? '安装失败',
    _ => e.toString(),
  };
}

final updateControllerProvider = NotifierProvider<UpdateController, UpdateState>(UpdateController.new);
