import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/danmaku/danmaku_client.dart';
import '../../data/danmaku/danmaku_models.dart';
import '../../data/media/media_models.dart';

/// 要找弹幕的那一集 / 那部电影
class DanmakuTarget {
  const DanmakuTarget({required this.title, required this.key, this.season, this.episode, this.movie = false});

  factory DanmakuTarget.of(MediaItem item) {
    final episode = item.kind == MediaKind.episode;
    return DanmakuTarget(
      title: episode ? (item.seriesName ?? item.name) : item.name,
      season: episode ? item.seasonNumber : null,
      episode: episode ? item.episodeNumber : null,
      movie: !episode,
      // 同一部剧的同一季共用一个手动选择
      key: episode
          ? '${item.serverId}/${item.seriesId ?? item.id}/s${item.seasonNumber ?? 0}'
          : '${item.serverId}/${item.id}',
    );
  }

  final String title;
  final int? season;
  final int? episode;
  final bool movie;

  /// 保存手动选择、时间偏移用的键
  final String key;

  /// 自动匹配用的文件名，如「凡人修仙传 S01E02」
  String get fileName {
    if (movie || season == null || episode == null) return title;
    String two(int n) => n.toString().padLeft(2, '0');
    return '$title S${two(season!)}E${two(episode!)}';
  }
}

/// 手动选择的作品与集数偏移、弹幕时间偏移（按剧 + 季记住）
class DanmakuChoice {
  const DanmakuChoice({this.server, this.animeId, this.animeTitle, this.offset = 0, this.shiftMs = 0});

  final String? server;
  final int? animeId;
  final String? animeTitle;

  /// 弹幕源集数 = 本地集数 + offset
  final int offset;

  /// 弹幕整体延后的毫秒数（负数 = 提前）
  final int shiftMs;

  bool get hasAnime => server != null && animeId != null;

  DanmakuChoice copyWith({int? shiftMs}) => DanmakuChoice(
    server: server,
    animeId: animeId,
    animeTitle: animeTitle,
    offset: offset,
    shiftMs: shiftMs ?? this.shiftMs,
  );

  Map<String, dynamic> toJson() => {
    'server': server,
    'animeId': animeId,
    'animeTitle': animeTitle,
    'offset': offset,
    'shiftMs': shiftMs,
  };

  factory DanmakuChoice.fromJson(Map<String, dynamic> j) => DanmakuChoice(
    server: j['server'] as String?,
    animeId: (j['animeId'] as num?)?.toInt(),
    animeTitle: j['animeTitle'] as String?,
    offset: (j['offset'] as num?)?.toInt() ?? 0,
    shiftMs: (j['shiftMs'] as num?)?.toInt() ?? 0,
  );
}

abstract final class DanmakuChoiceStore {
  static const _key = 'viora.danmaku.choices.v1';
  static const _max = 300;

  static Future<Map<String, dynamic>> _all() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      return raw == null ? {} : jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('danmaku choices: $e');
      return {};
    }
  }

  static Future<DanmakuChoice?> get(String key) async {
    final j = (await _all())[key];
    return j is Map<String, dynamic> ? DanmakuChoice.fromJson(j) : null;
  }

  static Future<void> set(String key, DanmakuChoice choice) async {
    final all = await _all();
    all.remove(key);
    all[key] = choice.toJson();
    while (all.length > _max) {
      all.remove(all.keys.first);
    }
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(all));
    } catch (e) {
      debugPrint('danmaku choices: $e');
    }
  }
}

/// 找到这一集的弹幕：先用记住的手动选择，再用服务器的自动匹配，最后按标题搜索取最像的一个
Future<DanmakuTrack?> resolveDanmaku(DanmakuClient client, DanmakuTarget t, {DanmakuChoice? choice}) async {
  if (choice != null && choice.hasAnime) {
    final anime = DanmakuAnime(server: choice.server!, animeId: choice.animeId!, title: choice.animeTitle ?? '');
    try {
      final track = await loadEpisodeOf(client, anime, t, offset: choice.offset);
      if (track != null) return track;
    } catch (e) {
      debugPrint('danmaku choice: $e');
    }
  }
  if (t.title.trim().isEmpty) return null;
  final m = await client.match(t.fileName);
  if (m != null) {
    final track = await client.load(m.server, m.episodeId, source: _source(m.animeTitle, m.episodeTitle));
    if (track.comments.isNotEmpty) return track;
  }
  final animes = await client.search(t.title, season: t.season, movie: t.movie);
  final best = animes.where((a) => _baseTitle(a.title).startsWith(t.title)).firstOrNull;
  if (best == null) return null;
  return loadEpisodeOf(client, best, t);
}

/// 选定作品后，按本地集数（加偏移）取对应的一集；电影取第一个
Future<DanmakuTrack?> loadEpisodeOf(DanmakuClient client, DanmakuAnime anime, DanmakuTarget t, {int offset = 0}) async {
  final eps = await client.episodes(anime);
  final ep = t.movie || t.episode == null ? eps.firstOrNull : pickEpisode(eps, t.episode! + offset);
  if (ep == null) return null;
  return client.load(anime.server, ep.episodeId, source: _source(anime.title, ep.title));
}

String _baseTitle(String s) => s.split(RegExp(r'[(（【]')).first.trim();

String _source(String anime, String episode) => [anime, episode].where((s) => s.trim().isNotEmpty).join(' · ');
