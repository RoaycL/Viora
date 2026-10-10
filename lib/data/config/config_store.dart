import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';

/// 配置读写：内存中是 [AppConfig]，每次修改后整体写回 shared_preferences。
class ConfigStore extends Notifier<AppConfig> {
  static const _key = 'viora.config.v1';

  bool _loaded = false;
  bool get loaded => _loaded;

  @override
  AppConfig build() => const AppConfig();

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      var config = raw == null ? const AppConfig() : AppConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
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

  Future<void> _write(AppConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(config.toJson()));
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
