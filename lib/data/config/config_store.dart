import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';

/// 保存密码、登录令牌的地方（系统密钥库）
abstract class SecretVault {
  Future<String?> read(String key);

  /// value 为 null / 空时删除
  Future<void> write(String key, String? value);
}

/// Android Keystore / Windows 凭据管理器
class SecureVault implements SecretVault {
  const SecureVault();
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String? value) =>
      value == null || value.isEmpty ? _storage.delete(key: key) : _storage.write(key: key, value: value);
}

/// 测试用
class MemoryVault implements SecretVault {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async =>
      value == null || value.isEmpty ? values.remove(key) : values[key] = value;
}

/// 配置读写：内存中是 [AppConfig]，每次修改后整体写回 shared_preferences。
///
/// 服务器密码和登录令牌存进系统密钥库（[vault]），配置 JSON 里不再有明文；
/// 部分电视盒子的密钥库不可用：写入失败时退回到保存在配置里，保证不会丢登录。
class ConfigStore extends Notifier<AppConfig> {
  static const _key = 'viora.config.v1';

  static SecretVault vault = const SecureVault();

  /// 密钥库可用（任何一次读写失败后本次运行都改存配置）
  bool _vaultOk = true;

  /// 已写入密钥库的值，避免每次改配置都重写
  final _written = <String, String?>{};

  // 配置与密钥库必须按同一顺序落盘，避免较慢的旧保存覆盖新配置。
  Future<void> _writes = Future<void>.value();

  static String _secretKey(String serverId, String field) => 'viora.server.$serverId.$field';

  static String _webdavKey(String field) => 'viora.webdav.$field';

  bool _loaded = false;
  bool get loaded => _loaded;

  @override
  AppConfig build() => const AppConfig();

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      var config = raw == null ? const AppConfig() : AppConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      config = await _readSecrets(config);
      if (config.deviceId.isEmpty) {
        config = config.copyWith(deviceId: newId());
        await _write(config);
      }
      state = config;
    } catch (e) {
      debugPrint('load config failed: $e');
      state = AppConfig(deviceId: newId());
    }
    _loaded = true;
  }

  /// 配置里没有密码 / 令牌的服务器从密钥库补上（旧版本的明文会在下次保存时移进密钥库）
  Future<AppConfig> _readSecrets(AppConfig config) async {
    try {
      final servers = <ServerConfig>[];
      for (final s in config.allServers) {
        final storedPassword = await vault.read(_secretKey(s.id, 'password'));
        final storedToken = await vault.read(_secretKey(s.id, 'token'));
        // 记下密钥库里已有的值：没变就不重写，删除服务器时知道要清哪些
        _written[_secretKey(s.id, 'password')] = storedPassword;
        _written[_secretKey(s.id, 'token')] = storedToken;
        final password = s.password.isNotEmpty ? s.password : storedPassword;
        final token = s.token ?? storedToken;
        servers.add(ServerConfig.fromJson({...s.toJson(), 'password': password ?? '', 'token': token}));
      }
      var webdav = config.webdav;
      for (final field in const ['password', 'passphrase']) {
        final stored = await vault.read(_webdavKey(field));
        _written[_webdavKey(field)] = stored;
        final current = webdav.toJson()[field] as String;
        if (current.isEmpty && stored != null) webdav = WebDavConfig.fromJson({...webdav.toJson(), field: stored});
      }
      return config.copyWith(servers: servers, webdav: webdav);
    } catch (e) {
      debugPrint('secret vault unavailable: $e');
      _vaultOk = false;
      return config;
    }
  }

  Future<void> _put(String key, String? value) async {
    if (_written.containsKey(key) && _written[key] == value) return;
    await vault.write(key, value);
    _written[key] = value;
  }

  Future<void> _write(AppConfig config) async {
    final json = config.toJson();
    if (_vaultOk) {
      try {
        final ids = {for (final s in config.allServers) s.id};
        for (final s in config.allServers) {
          await _put(_secretKey(s.id, 'password'), s.password);
          await _put(_secretKey(s.id, 'token'), s.token);
        }
        await _put(_webdavKey('password'), config.webdav.password);
        await _put(_webdavKey('passphrase'), config.webdav.passphrase);
        json['webdav'] = {...json['webdav'] as Map<String, dynamic>, 'password': '', 'passphrase': ''};
        // 删掉已移除服务器的密码
        for (final key in [..._written.keys]) {
          if (!key.startsWith('viora.server.')) continue;
          final id = key.split('.').elementAtOrNull(2);
          if (id != null && !ids.contains(id) && _written[key] != null) await _put(key, null);
        }
        for (final s in json['servers'] as List) {
          (s as Map<String, dynamic>)
            ..['password'] = ''
            ..['token'] = null;
        }
      } catch (e) {
        debugPrint('secret vault write failed, keeping secrets in config: $e');
        _vaultOk = false;
        json['servers'] = config.allServers.map((s) => s.toJson()).toList();
        json['webdav'] = config.webdav.toJson();
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(json));
  }

  Future<void> update(AppConfig Function(AppConfig) change) {
    state = change(state);
    final snapshot = state;
    final task = _writes.then((_) => _write(snapshot));
    _writes = task.catchError((Object e) {
      debugPrint('save config failed: $e');
    });
    return _writes;
  }

  /// 后台连接（导入配置后自动登录）的结果写回：服务器已删除、或地址 / 账号 / 密码 / UA 被改过时不写回，返回 false。
  ///
  /// 只比较这些决定「连的是哪台、用哪个账号」的字段：连接期间首页测速、播放器刷新登录也会更新这台服务器
  /// （测速延迟、令牌等），那些变化不能让这次连接结果被丢掉。写回时只合并连接得到的字段（令牌、用户、
  /// 线路测速、服务器名、访问时间），连接期间用户改的其他设置（聚合、索引、成人内容等）保留
  Future<bool> replaceServerIfUnchanged(ServerConfig expected, ServerConfig replacement) async {
    final current = state.server(expected.id);
    if (current == null || _identityOf(current) != _identityOf(expected)) return false;
    await updateServer(expected.id, (s) {
      if (_identityOf(s) != _identityOf(expected)) return s;
      // 令牌 / 用户 / 当前线路：只有这次连接自己改了（重新登录、换线路）才写回。
      // 连接期间前台请求可能已经刷新了过期的令牌，不能用后台快照里的旧令牌覆盖回去
      final sessionChanged = replacement.token != expected.token || replacement.userId != expected.userId;
      return s.copyWith(
        name: s.name.trim().isEmpty ? replacement.name : null,
        lines: replacement.lines,
        userId: sessionChanged ? replacement.userId : null,
        token: sessionChanged ? replacement.token : null,
        activeLineId: replacement.activeLineId != expected.activeLineId ? replacement.activeLineId : null,
        lastAccessAt: replacement.lastAccessAt,
      );
    });
    return true;
  }

  static String _identityOf(ServerConfig s) => [
    s.type.name,
    s.username,
    s.password,
    s.userAgent,
    for (final l in s.lines) '${l.id}|${l.url}|${l.proxied}',
  ].join('\u0001');

  Future<void> upsertServer(ServerConfig server) => update((c) {
    final list = [...c.allServers];
    final i = list.indexWhere((s) => s.id == server.id);
    if (i >= 0) {
      list[i] = server;
    } else {
      list.add(server);
    }
    return c.copyWith(servers: list);
  });

  Future<void> updateServer(String id, ServerConfig Function(ServerConfig) change) => update((c) {
    return c.copyWith(servers: [for (final s in c.allServers) s.id == id ? change(s) : s]);
  });

  Future<void> removeServer(String id) =>
      update((c) => c.copyWith(servers: c.allServers.where((s) => s.id != id).toList()));
}

final configProvider = NotifierProvider<ConfigStore, AppConfig>(ConfigStore.new);
