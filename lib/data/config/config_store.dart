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

  static String _secretKey(String serverId, String field) => 'viora.server.$serverId.$field';

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
      for (final s in config.servers) {
        final storedPassword = await vault.read(_secretKey(s.id, 'password'));
        final storedToken = await vault.read(_secretKey(s.id, 'token'));
        // 记下密钥库里已有的值：没变就不重写，删除服务器时知道要清哪些
        _written[_secretKey(s.id, 'password')] = storedPassword;
        _written[_secretKey(s.id, 'token')] = storedToken;
        final password = s.password.isNotEmpty ? s.password : storedPassword;
        final token = s.token ?? storedToken;
        servers.add(ServerConfig.fromJson({...s.toJson(), 'password': password ?? '', 'token': token}));
      }
      return config.copyWith(servers: servers);
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
        final ids = {for (final s in config.servers) s.id};
        for (final s in config.servers) {
          await _put(_secretKey(s.id, 'password'), s.password);
          await _put(_secretKey(s.id, 'token'), s.token);
        }
        // 删掉已移除服务器的密码
        for (final key in [..._written.keys]) {
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
        json['servers'] = config.servers.map((s) => s.toJson()).toList();
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(json));
  }

  Future<void> update(AppConfig Function(AppConfig) change) async {
    state = change(state);
    try {
      await _write(state);
    } catch (e) {
      debugPrint('save config failed: $e');
    }
  }

  Future<void> upsertServer(ServerConfig server) => update((c) {
    final list = [...c.servers];
    final i = list.indexWhere((s) => s.id == server.id);
    if (i >= 0) {
      list[i] = server;
    } else {
      list.add(server);
    }
    return c.copyWith(servers: list);
  });

  Future<void> updateServer(String id, ServerConfig Function(ServerConfig) change) => update((c) {
    return c.copyWith(servers: [for (final s in c.servers) s.id == id ? change(s) : s]);
  });

  Future<void> removeServer(String id) =>
      update((c) => c.copyWith(servers: c.servers.where((s) => s.id != id).toList()));
}

final configProvider = NotifierProvider<ConfigStore, AppConfig>(ConfigStore.new);
