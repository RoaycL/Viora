import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/config/app_config.dart';
import '../../data/config/config_store.dart';
import '../../data/net/request_composer.dart';
import '../../data/sync/config_payload.dart';
import '../../data/sync/webdav_sync.dart';
import '../../domain/models/segment_settings.dart';
import '../segments/segment_service.dart';
import 'sync_settings_section.dart' show applySyncPayload;

/// 同步方向
enum WebDavSyncMode {
  /// 自动判断：只有本机改了 → 上传；只有云端改了 → 下载；都改了 → 合并后上传
  auto,

  /// 用本机配置覆盖云端
  upload,

  /// 用云端配置覆盖本机（本机有、云端没有的服务器会删掉）
  download,
}

/// 状态（设置页显示）
class WebDavStatus {
  const WebDavStatus({this.running = false, this.message, this.error = false, this.at});

  final bool running;
  final String? message;
  final bool error;
  final DateTime? at;
}

/// WebDAV 同步（docs/11-sync.md §WebDAV）：
/// 云端是一个配置文件（与局域网同步、备份同一格式，可选加密），每次上传带一个新的版本号 `rev`。
/// 本机记下上次同步时的配置摘要和云端版本号，据此判断哪边改过：
/// - 只有本机改了：上传
/// - 只有云端改了：下载，并按云端删除本机多出的服务器（删除也能同步）
/// - 两边都改了：合并（不删除）后上传
class WebDavSync {
  WebDavSync(this._container, {this.stateKey = 'viora.webdav.state'});

  final ProviderContainer _container;

  /// 本机同步状态存在 shared_preferences 的这个键下（测试里模拟两台设备时各用各的）
  final String stateKey;

  /// 启动后注册的实例（设置页用）
  static WebDavSync? instance;

  final status = ValueNotifier(const WebDavStatus());

  Future<String>? _running;
  Timer? _debounce;
  bool _pendingCheck = false;
  final _subscriptions = <ProviderSubscription<Object?>>[];

  /// 开启自动同步：启动时同步一次，之后配置变化 8 秒后同步
  void start() {
    _subscriptions
      ..add(
        _container.listen<AppConfig>(configProvider, (AppConfig? prev, AppConfig next) async {
          // 换了 WebDAV（包括从手机 / 电脑同步过来）：按第一次同步处理，马上同步
          if (prev != null && _identity(prev.webdav) != _identity(next.webdav)) {
            await resetState();
            _scheduleAuto(delay: const Duration(seconds: 2), checkRemote: true);
          } else {
            _scheduleAuto();
          }
        }),
      )
      ..add(_container.listen(segmentSettingsProvider, (_, _) => _scheduleAuto()));
    _scheduleAuto(delay: const Duration(seconds: 3), checkRemote: true);
  }

  static String _identity(WebDavConfig c) => [c.url.trim(), c.username, c.path, c.passphrase].join('\u0001');

  void dispose() {
    _debounce?.cancel();
    for (final s in _subscriptions) {
      s.close();
    }
    status.dispose();
  }

  /// [checkRemote]：启动时即使本机没改也要看看云端有没有更新
  void _scheduleAuto({Duration delay = const Duration(seconds: 8), bool checkRemote = false}) {
    final c = _container.read(configProvider).webdav;
    if (!c.configured || !c.autoSync) return;
    final pendingCheck = _pendingCheck || checkRemote;
    _pendingCheck = pendingCheck;
    _debounce?.cancel();
    _debounce = Timer(delay, () async {
      _pendingCheck = false;
      try {
        // 本机没改：不用访问云端
        if (!pendingCheck && await _localHash() == (await _loadState()).hash) return;
        await sync();
      } catch (e) {
        debugPrint('webdav auto sync failed: $e');
      }
    });
  }

  Future<SegmentSettings?> _segments() async {
    try {
      return await _container.read(segmentSettingsProvider.future);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _payload() async => buildSyncPayload(
    _container.read(configProvider),
    sections: {...SyncSection.values}..remove(SyncSection.webdav),
    segments: await _segments(),
    from: defaultDeviceName(),
  );

  /// 配置内容的摘要（不含来源、版本号等每次都变的字段）
  static String hashOf(Map<String, dynamic> payload) {
    final copy = {...payload}..removeWhere((k, _) => const {'from', 'rev', 'updatedAt'}.contains(k));
    return sha1.convert(utf8.encode(jsonEncode(copy))).toString();
  }

  Future<String> _localHash() async => hashOf(await _payload());

  Future<({String? hash, String? rev, DateTime? checkedAt})> _loadState() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(stateKey);
      if (raw == null) return (hash: null, rev: null, checkedAt: null);
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return (
        hash: j['hash'] as String?,
        rev: j['rev'] as String?,
        checkedAt: DateTime.tryParse(j['at'] as String? ?? ''),
      );
    } catch (_) {
      return (hash: null, rev: null, checkedAt: null);
    }
  }

  Future<void> _saveState(String hash, String? rev) async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        stateKey,
        jsonEncode({'hash': hash, 'rev': rev, 'at': DateTime.now().toIso8601String()}),
      );
    } catch (_) {}
  }

  /// 换了 WebDAV 地址 / 文件后，下一次同步按「第一次同步」处理（两边合并）
  Future<void> resetState() async {
    try {
      await (await SharedPreferences.getInstance()).remove(stateKey);
    } catch (_) {}
  }

  /// 同步一次，返回给用户看的结果；失败抛 [WebDavException]
  Future<String> sync({WebDavSyncMode mode = WebDavSyncMode.auto}) {
    final running = _running;
    if (running != null) return running;
    final f = _sync(mode);
    _running = f;
    status.value = WebDavStatus(running: true, message: '正在同步…', at: status.value.at);
    f.then(
      (m) => status.value = WebDavStatus(message: m, at: DateTime.now()),
      onError: (Object e) => status.value = WebDavStatus(message: '$e', error: true, at: DateTime.now()),
    );
    return f.whenComplete(() => _running = null);
  }

  Future<String> _sync(WebDavSyncMode mode) async {
    final config = _container.read(configProvider).webdav;
    if (!config.configured) throw const WebDavException('还没有填写 WebDAV 地址');
    final client = WebDavClient(config);
    final local = await _payload();
    final localHash = hashOf(local);
    final state = await _loadState();

    if (mode == WebDavSyncMode.upload) {
      await _upload(client, config, local, localHash);
      return '已用本机配置覆盖云端';
    }

    final text = await client.read();
    if (text == null) {
      if (mode == WebDavSyncMode.download) throw const WebDavException('云端还没有配置文件');
      await _upload(client, config, local, localHash);
      return '云端还没有配置，已上传本机配置';
    }
    Map<String, dynamic> remote;
    try {
      remote = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      throw const WebDavException('云端文件不是 Viora 的配置');
    }
    if (WebDavCrypto.isEncrypted(remote)) remote = await WebDavCrypto.decrypt(remote, config.passphrase);
    if (remote['viora'] is! num) throw const WebDavException('云端文件不是 Viora 的配置');
    final rev = remote['rev'] as String?;
    final remoteChanged = rev == null || rev != state.rev;
    final localChanged = localHash != state.hash;
    final from = (remote['from'] as String?)?.trim();
    final source = from == null || from.isEmpty ? '云端' : '云端（$from）';

    if (mode == WebDavSyncMode.download || (remoteChanged && !localChanged)) {
      final message = await _apply(remote, replaceServers: true);
      await _saveState(await _localHash(), rev);
      return '已从$source下载：$message';
    }
    if (remoteChanged && localChanged) {
      // 两边都改过：合并（不删除任何一边的服务器），再把合并结果传上去
      final message = await _apply(remote, replaceServers: false);
      final merged = await _payload();
      await _upload(client, config, merged, hashOf(merged));
      return '已合并$source的配置并上传：$message';
    }
    if (localChanged) {
      await _upload(client, config, local, localHash);
      return '已上传本机的修改';
    }
    await _saveState(localHash, rev);
    return '已是最新';
  }

  Future<String> _apply(Map<String, dynamic> remote, {required bool replaceServers}) async {
    final message = await applySyncPayload(
      _container,
      remote,
      (line) => debugPrint('webdav: $line'),
      replaceServers: replaceServers,
    );
    return message.replaceFirst('已导入：', '');
  }

  Future<void> _upload(WebDavClient client, WebDavConfig config, Map<String, dynamic> payload, String hash) async {
    final rev = newId();
    var file = {...payload, 'rev': rev, 'updatedAt': DateTime.now().toUtc().toIso8601String()};
    if (config.passphrase.isNotEmpty) file = await WebDavCrypto.encrypt(file, config.passphrase);
    await client.write(const JsonEncoder.withIndent('  ').convert(file));
    await _saveState(hash, rev);
  }
}
