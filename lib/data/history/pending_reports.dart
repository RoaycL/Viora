import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../emby/emby_client.dart';
import '../media/media_models.dart';

/// 还没报到服务器的「停止播放」上报。
///
/// 退出播放时先存在本机，服务器收到后删掉。应用在上报发完之前就被关掉（退出后马上关应用、更新、断电）时，
/// 下次启动补发，这次播放的进度不会丢。
class PendingPlayReport {
  const PendingPlayReport({
    required this.serverId,
    required this.account,
    required this.itemId,
    required this.sourceId,
    required this.position,
    required this.at,
    this.playSessionId,
  });

  final String serverId;

  /// 账号身份（换了账号的不补发）
  final String account;
  final String itemId;
  final String sourceId;
  final Duration position;

  /// 退出播放的时间
  final DateTime at;
  final String? playSessionId;

  String get key => '$account/$itemId';

  Map<String, Object?> toJson() => {
    'serverId': serverId,
    'account': account,
    'itemId': itemId,
    'sourceId': sourceId,
    'positionMs': position.inMilliseconds,
    'at': at.toUtc().toIso8601String(),
    'session': playSessionId,
  };

  static PendingPlayReport? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse(j['at'] as String? ?? '');
    final ms = j['positionMs'];
    if (at == null || ms is! int) return null;
    return PendingPlayReport(
      serverId: j['serverId'] as String? ?? '',
      account: j['account'] as String? ?? '',
      itemId: j['itemId'] as String? ?? '',
      sourceId: j['sourceId'] as String? ?? '',
      position: Duration(milliseconds: ms),
      at: at,
      playSessionId: j['session'] as String?,
    );
  }
}

abstract final class PendingPlayReports {
  static const _key = 'viora.pendingPlayReports.v1';

  /// 超过这个时间还没补发成功的不再补（那时服务器上很可能已经有更新的记录）
  static const maxAge = Duration(days: 3);

  static Future<Map<String, PendingPlayReport>> _all() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return {};
      final list = jsonDecode(raw) as List;
      return {for (final r in list.map(PendingPlayReport.fromJson).whereType<PendingPlayReport>()) r.key: r};
    } catch (e) {
      debugPrint('pending reports: $e');
      return {};
    }
  }

  static Future<void> _save(Map<String, PendingPlayReport> all) async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        _key,
        jsonEncode([for (final r in all.values) r.toJson()]),
      );
    } catch (e) {
      debugPrint('pending reports: $e');
    }
  }

  static Future<void> add(PendingPlayReport r) async {
    final all = await _all();
    all[r.key] = r;
    await _save(all);
  }

  /// 服务器收到了：删掉（只删同一次退出的那条，之后又播放过的新记录保留）
  static Future<void> done(PendingPlayReport r) async {
    final all = await _all();
    final cur = all[r.key];
    if (cur == null || cur.at.isAfter(r.at)) return;
    all.remove(r.key);
    await _save(all);
  }

  static Future<List<PendingPlayReport>> list() async => (await _all()).values.toList();

  /// 启动时补发。[clientFor] 返回这条记录所在服务器的客户端（账号不同 / 服务器已删除时返回 null，记录丢掉）。
  ///
  /// 服务器上这一集在退出之后又有播放记录（在别的设备上看过）时不补发，免得用旧进度覆盖新的。
  /// 返回补发成功的条数
  static Future<int> flush(EmbyClient? Function(PendingPlayReport r) clientFor, {DateTime? now}) async {
    final all = await _all();
    if (all.isEmpty) return 0;
    final current = now ?? DateTime.now();
    var sent = 0;
    for (final r in all.values.toList()) {
      if (current.difference(r.at) > maxAge) {
        all.remove(r.key);
        continue;
      }
      final client = clientFor(r);
      if (client == null) {
        all.remove(r.key);
        continue;
      }
      try {
        final item = await client.item(r.itemId);
        // 服务器时间和本机可能差一点：晚 2 分钟以上才算「之后又看过」
        final later = item.lastPlayed;
        if (later != null && later.isAfter(r.at.add(const Duration(minutes: 2)))) {
          debugPrint('pending report ${r.itemId}: 服务器上之后又播放过，不补发');
          all.remove(r.key);
          continue;
        }
      } catch (_) {
        continue; // 服务器暂时连不上：下次再试
      }
      final ok = await client.reportStopped(
        MediaSourceInfo(serverId: r.serverId, itemId: r.itemId, id: r.sourceId, container: ''),
        r.position,
        r.playSessionId,
      );
      if (ok) {
        all.remove(r.key);
        sent++;
        debugPrint('pending report ${r.itemId}: 补发成功 @${r.position.inSeconds}s');
      }
    }
    await _save(all);
    return sent;
  }
}
