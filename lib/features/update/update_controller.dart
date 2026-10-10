import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_version.dart';
import 'update_source.dart';

/// 默认更新源：本项目的 GitHub Releases。
const defaultUpdateOwner = 'RoaycL';
const defaultUpdateRepo = 'Viora';

/// 更新设置（持久化在 shared_preferences）。
class UpdateSettings {
  const UpdateSettings({this.autoCheck = true, this.manifestUrl});

  final bool autoCheck;

  /// 非空时使用自定义清单地址，否则使用 GitHub Releases
  final String? manifestUrl;

  static const _kAutoCheck = 'update.autoCheck';
  static const _kManifest = 'update.manifestUrl';

  static Future<UpdateSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_kManifest);
    return UpdateSettings(
      autoCheck: prefs.getBool(_kAutoCheck) ?? true,
      manifestUrl: url == null || url.isEmpty ? null : url,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoCheck, autoCheck);
    await prefs.setString(_kManifest, manifestUrl ?? '');
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

  Future<UpdateSource> _source() async {
    final p = await packageInfo;
    final ua = 'Viora/${p.version} (${Platform.operatingSystem})';
    final manifest = settings.manifestUrl;
    if (manifest != null) return ManifestSource(Uri.parse(manifest), userAgent: ua);
    return GitHubReleasesSource(defaultUpdateOwner, defaultUpdateRepo, userAgent: ua);
  }

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
      final latest = await (await _source()).latest(platform);
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
      final request = await client.getUrl(info.downloadUrl);
      final response = await request.close();
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
