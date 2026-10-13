import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../config/app_config.dart';

/// 账号和服务器身份。令牌、密码、测速、当前线路变化不会改变账号的数据空间。
String accountScope(ServerConfig server) => _digest([
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

String indexAccountsKey(AppConfig config) => _digest(indexAccountScopes(config));

String _digest(Object value) => sha256.convert(utf8.encode(jsonEncode(value))).toString();
