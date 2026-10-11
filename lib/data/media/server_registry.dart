import '../history/play_history.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../config/config_store.dart';
import '../emby/emby_client.dart';
import 'media_models.dart';

/// 应用版本号（main() 启动时从 package_info 读入；测试中保持默认值）。
String appVersion = '0.0.0';

/// 按服务器 ID 取客户端。配置变化（登录令牌、线路、代理、UA）时自动重建。
final serverClientProvider = Provider.family<EmbyClient?, String>((ref, serverId) {
  // 只在这台服务器的连接信息（登录、线路、代理、UA）变化时重建。
  // 测速延迟、片量、访问时间等写回配置时不重建，避免依赖它的列表全部重新请求服务器。
  ref.watch(configProvider.select((c) => c.clientKey(serverId)));
  final config = ref.read(configProvider);
  final server = config.server(serverId);
  if (server == null) return null;
  final store = ref.read(configProvider.notifier);
  return EmbyClient(
    config: config,
    server: server,
    appVersion: appVersion,
    onServerChanged: (s) => store.updateServer(
      s.id,
      (old) => old.copyWith(token: s.token, userId: s.userId, lines: s.lines, clearSession: s.token == null),
    ),
  );
});

/// 为新服务器（还未保存）创建客户端，用于添加服务器时的连接测试与登录。
EmbyClient clientForDraft(AppConfig config, ServerConfig server) =>
    EmbyClient(config: config, server: server, appVersion: appVersion);

/// 所有已登录服务器的"继续观看"，按服务器返回顺序合并（docs/05 §2.1）。
final resumeProvider = FutureProvider<List<MediaItem>>((ref) async {
  ref.watch(configProvider.select((c) => c.serversKey));
  final config = ref.read(configProvider);
  final results = await Future.wait(
    config.servers.where((s) => s.loggedIn).map((s) async {
      try {
        return await ref.read(serverClientProvider(s.id))!.resume(limit: 12);
      } catch (_) {
        return const <MediaItem>[];
      }
    }),
  );
  // 各服务器按上次播放时间合并
  final all = [for (final list in results) ...list];
  // 服务器没给上次播放时间时用本机记录的
  final epoch = DateTime(1970);
  all.sort((a, b) => (PlayHistory.lastPlayed(b) ?? epoch).compareTo(PlayHistory.lastPlayed(a) ?? epoch));
  return all;
});

final librariesProvider = FutureProvider.family<List<Library>, String>((ref, serverId) async {
  final client = ref.watch(serverClientProvider(serverId));
  if (client == null) return const [];
  return client.libraries();
});

final latestProvider = FutureProvider.family<List<MediaItem>, ({String serverId, String libraryId})>((ref, key) async {
  final client = ref.watch(serverClientProvider(key.serverId));
  if (client == null) return const [];
  return client.latest(parentId: key.libraryId, limit: 16);
});

final itemProvider = FutureProvider.family<MediaItem, ({String serverId, String itemId})>((ref, key) async {
  final client = ref.watch(serverClientProvider(key.serverId));
  if (client == null) throw const MediaServerException('服务器不存在');
  return client.item(key.itemId);
});

/// 当前能显示的条目：所在服务器可见（儿童模式隐藏 R18 服务器），分级在允许范围内（单集跟随剧集）
bool itemVisible(AppConfig c, MediaItem it) =>
    c.server(it.serverId) != null &&
    (!c.parental.enabled || it.kind == MediaKind.episode || c.parental.allows(it.officialRating));
