import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../config/app_config.dart';

/// 账号和服务器身份：服务器、类型、用户名、用户 ID。
/// 令牌、密码、测速、线路（增删、改地址）变化都不算换账号，不清空这台服务器的索引、快照和观看记录。
String accountScope(ServerConfig server) => _digest([server.id, server.type.name, server.username, server.userId]);

/// 0.15.14 之前的账号身份（包含全部线路地址），只用于把旧数据迁移到新的身份下
String legacyAccountScope(ServerConfig server) => _digest([
  server.id,
  server.type.name,
  server.username,
  server.userId,
  (server.lines.map((l) => l.url.trim().replaceFirst(RegExp(r'/+$'), '')).toSet().toList()..sort()),
]);

/// 页面查询受到家长控制影响，不能把受限查询覆盖到未受限的快照中。
String mediaViewScope(AppConfig config) => _digest([
  config.parental.enabled,
  if (config.parental.enabled) ...[config.parental.maxAge, config.parental.blockUnrated],
]);

String mediaFeedScope(AppConfig config) => _digest([
  mediaViewScope(config),
  for (final server in config.servers.where((s) => s.loggedIn)) accountScope(server),
]);

Map<String, String> indexAccountScopes(AppConfig config) => {
  for (final server in config.allServers.where((s) => s.loggedIn)) server.id: accountScope(server),
};

/// 各服务器旧格式的账号身份（迁移用）
Map<String, String> legacyIndexAccountScopes(AppConfig config) => {
  for (final server in config.allServers.where((s) => s.loggedIn)) server.id: legacyAccountScope(server),
};

String indexAccountsKey(AppConfig config) => _digest(indexAccountScopes(config));

String _digest(Object value) => sha256.convert(utf8.encode(jsonEncode(value))).toString();
