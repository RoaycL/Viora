import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../media/media_models.dart';

/// 本机记录的上次播放时间。部分服务器（如某些 Emby）的继续观看列表不带 LastPlayedDate，
/// 这时用 Viora 自己记录的时间显示"5 小时前"并排序。启动时读入内存，查询是同步的。
abstract final class PlayHistory {
  static const _key = 'viora.playHistory.v1';
  static const _max = 500;
  static Map<String, int> _times = {};

  static String _id(String serverId, String itemId) => '$serverId/$itemId';

  static Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null) _times = (jsonDecode(raw) as Map<String, dynamic>).map((k, v) => MapEntry(k, v as int));
    } catch (e) {
      debugPrint('play history: $e');
    }
  }

  /// 服务器给的上次播放时间优先，没有时用本机记录的
  static DateTime? lastPlayed(MediaItem item) {
    if (item.lastPlayed != null) return item.lastPlayed;
    final ms = _times[_id(item.serverId, item.id)];
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<void> record(String serverId, String itemId) async {
    final id = _id(serverId, itemId);
    _times.remove(id);
    _times[id] = DateTime.now().millisecondsSinceEpoch;
    while (_times.length > _max) {
      _times.remove(_times.keys.first);
    }
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(_times));
    } catch (e) {
      debugPrint('play history: $e');
    }
  }
}
