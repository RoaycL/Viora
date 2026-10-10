import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' if (dart.library.js_interop) 'sqlite_stub.dart';

import '../media/media_models.dart';
import 'title_norm.dart';

/// 本地聚合索引（docs/04-aggregation.md §1~§3）：
/// 每台服务器的电影与剧集（不含单集）存进 SQLite，用于秒出搜索结果和跨服务器匹配同一部作品。
class MediaIndex {
  MediaIndex._(this._db) {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS items(
        server_id TEXT NOT NULL,
        item_id TEXT NOT NULL,
        kind INTEGER NOT NULL,
        name TEXT NOT NULL,
        norm TEXT NOT NULL,
        initials TEXT NOT NULL,
        pinyin TEXT NOT NULL,
        year INTEGER,
        tmdb TEXT,
        imdb TEXT,
        tvdb TEXT,
        created INTEGER,
        gen INTEGER NOT NULL DEFAULT 0,
        json TEXT NOT NULL,
        PRIMARY KEY(server_id, item_id)
      );
      CREATE INDEX IF NOT EXISTS items_tmdb ON items(tmdb);
      CREATE INDEX IF NOT EXISTS items_imdb ON items(imdb);
      CREATE INDEX IF NOT EXISTS items_tvdb ON items(tvdb);
      CREATE INDEX IF NOT EXISTS items_norm ON items(norm);
      CREATE TABLE IF NOT EXISTS sync_state(
        server_id TEXT PRIMARY KEY,
        full_at INTEGER,
        incr_at INTEGER,
        gen INTEGER NOT NULL DEFAULT 0
      );
    ''');
  }

  final Database _db;

  /// 打开（或创建）索引数据库；[path] 为空时放在应用数据目录。测试可传 ':memory:'。
  static Future<MediaIndex?> open({String? path}) async {
    if (kIsWeb) return null;
    try {
      if (path == ':memory:') return MediaIndex._(sqlite3.openInMemory());
      final dir = path == null ? (await getApplicationSupportDirectory()).path : null;
      final file = path ?? '$dir${Platform.pathSeparator}viora_index.db';
      final db = sqlite3.open(file)..execute('PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;');
      return MediaIndex._(db);
    } catch (e) {
      debugPrint('open index failed: $e');
      return null;
    }
  }

  void close() => _db.close();

  // ───────────────────────── 写入 ─────────────────────────

  ({DateTime? fullAt, DateTime? incrAt, int gen}) syncState(String serverId) {
    final r = _db.select('SELECT full_at, incr_at, gen FROM sync_state WHERE server_id = ?', [serverId]);
    if (r.isEmpty) return (fullAt: null, incrAt: null, gen: 0);
    DateTime? t(Object? v) => v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);
    return (fullAt: t(r.first['full_at']), incrAt: t(r.first['incr_at']), gen: r.first['gen'] as int);
  }

  void _setState(String serverId, {DateTime? fullAt, DateTime? incrAt, int? gen}) {
    final s = syncState(serverId);
    _db.execute('INSERT OR REPLACE INTO sync_state(server_id, full_at, incr_at, gen) VALUES (?, ?, ?, ?)', [
      serverId,
      (fullAt ?? s.fullAt)?.millisecondsSinceEpoch,
      (incrAt ?? s.incrAt)?.millisecondsSinceEpoch,
      gen ?? s.gen,
    ]);
  }

  /// 写入一批条目；[gen] 为本次全量同步的代号（增量同步沿用当前代号）
  void upsert(String serverId, List<MediaItem> items, {int? gen}) {
    if (items.isEmpty) return;
    final g = gen ?? syncState(serverId).gen;
    final stmt = _db.prepare('''
      INSERT OR REPLACE INTO items(server_id, item_id, kind, name, norm, initials, pinyin, year, tmdb, imdb, tvdb, created, gen, json)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''');
    _db.execute('BEGIN');
    try {
      for (final it in items) {
        if (it.kind != MediaKind.movie && it.kind != MediaKind.series) continue;
        stmt.execute([
          serverId,
          it.id,
          it.kind.index,
          it.name,
          normalizeTitle(it.name),
          titleInitials(it.name),
          titlePinyin(it.name),
          it.year,
          _blankToNull(it.tmdbId),
          _blankToNull(it.imdbId),
          _blankToNull(it.tvdbId),
          it.dateCreated?.millisecondsSinceEpoch,
          g,
          jsonEncode(it.toIndexJson()),
        ]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      stmt.close();
    }
  }

  static String? _blankToNull(String? s) => s == null || s.trim().isEmpty ? null : s.trim();

  /// 开始一次全量同步，返回新的代号
  int beginFull(String serverId) => syncState(serverId).gen + 1;

  /// 全量同步完成：删除这一轮没有出现的条目（服务器上已删除）
  void finishFull(String serverId, int gen) {
    _db.execute('DELETE FROM items WHERE server_id = ? AND gen <> ?', [serverId, gen]);
    final now = DateTime.now();
    _setState(serverId, fullAt: now, incrAt: now, gen: gen);
  }

  void finishIncremental(String serverId, DateTime startedAt) => _setState(serverId, incrAt: startedAt);

  void removeServer(String serverId) {
    _db.execute('DELETE FROM items WHERE server_id = ?', [serverId]);
    _db.execute('DELETE FROM sync_state WHERE server_id = ?', [serverId]);
  }

  /// 只保留这些服务器的数据（删除已移除服务器的残留）
  void retainServers(Set<String> serverIds) {
    final rows = _db.select('SELECT DISTINCT server_id FROM items');
    for (final r in rows) {
      final id = r['server_id'] as String;
      if (!serverIds.contains(id)) removeServer(id);
    }
  }

  // ───────────────────────── 查询 ─────────────────────────

  int count(String serverId) =>
      _db.select('SELECT COUNT(*) AS c FROM items WHERE server_id = ?', [serverId]).first['c'] as int;

  MediaItem _row(Row r) => MediaItem.fromIndexJson(
    r['server_id'] as String,
    r['item_id'] as String,
    jsonDecode(r['json'] as String) as Map<String, Object?>,
  );

  /// 搜索：中文按归一化标题包含；字母按拼音首字母前缀、全拼包含、英文标题包含
  List<MediaItem> search(String query, {int limit = 300}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final norm = normalizeTitle(q);
    if (norm.isEmpty) return const [];
    final latin = RegExp(r'^[a-z0-9]+$').hasMatch(norm);
    final rows = latin
        ? _db.select(
            '''SELECT * FROM items
               WHERE initials LIKE ? OR pinyin LIKE ? OR norm LIKE ?
               ORDER BY (norm = ?) DESC, (initials = ?) DESC, created DESC LIMIT ?''',
            ['$norm%', '%$norm%', '%$norm%', norm, norm, limit],
          )
        : _db.select('SELECT * FROM items WHERE norm LIKE ? ORDER BY (norm = ?) DESC, created DESC LIMIT ?', [
            '%$norm%',
            norm,
            limit,
          ]);
    return rows.map(_row).toList();
  }

  /// 所有服务器上与 [item] 是同一部作品的条目（含 [item] 所在服务器上的同名副本）
  List<MediaItem> matches(MediaItem item) {
    final norm = normalizeTitle(item.name);
    final rows = _db.select(
      '''SELECT * FROM items WHERE kind = ? AND (
           (tmdb IS NOT NULL AND tmdb = ?) OR (imdb IS NOT NULL AND imdb = ?) OR (tvdb IS NOT NULL AND tvdb = ?)
           OR (norm = ? AND norm <> ''))''',
      [item.kind.index, _blankToNull(item.tmdbId), _blankToNull(item.imdbId), _blankToNull(item.tvdbId), norm],
    );
    return rows.map(_row).where((c) => sameTitle(item, c)).toList();
  }

  /// 按 TMDB ID 查找媒体库里的副本（首页推荐标注资源数、点进去直接打开媒体库条目）
  List<MediaItem> byTmdb(MediaKind kind, String tmdbId, {String? imdbId}) {
    final rows = _db.select('SELECT * FROM items WHERE kind = ? AND (tmdb = ? OR (imdb IS NOT NULL AND imdb = ?))', [
      kind.index,
      tmdbId,
      _blankToNull(imdbId),
    ]);
    return rows.map(_row).toList();
  }

  /// 按服务器分组的最近入库
  List<MediaItem> latest({int limit = 40}) =>
      _db.select('SELECT * FROM items ORDER BY created DESC LIMIT ?', [limit]).map(_row).toList();
}

/// 两个条目是否为同一部作品（docs/04-aggregation.md §3）：
/// 优先比较 TMDB / IMDb / TVDB；双方都有 ID 但不同则不是；都没有可比的 ID 时按标题 + 年份（±1）。
bool sameTitle(MediaItem a, MediaItem b) {
  if (a.kind != b.kind) return false;
  bool? cmp(String? x, String? y) {
    final p = x?.trim(), q = y?.trim();
    if (p == null || p.isEmpty || q == null || q.isEmpty) return null;
    return p == q;
  }

  for (final r in [cmp(a.tmdbId, b.tmdbId), cmp(a.imdbId, b.imdbId), cmp(a.tvdbId, b.tvdbId)]) {
    if (r != null) return r;
  }
  if (normalizeTitle(a.name) != normalizeTitle(b.name)) return false;
  if (a.year != null && b.year != null && (a.year! - b.year!).abs() > 1) return false;
  return true;
}

/// 用于去重 / 分组的作品键
String titleKeyOf(MediaItem it) {
  final k = it.kind.name;
  if (it.tmdbId?.isNotEmpty == true) return 'tmdb:$k:${it.tmdbId}';
  if (it.imdbId?.isNotEmpty == true) return 'imdb:$k:${it.imdbId}';
  if (it.tvdbId?.isNotEmpty == true) return 'tvdb:$k:${it.tvdbId}';
  return 'title:$k:${normalizeTitle(it.name)}:${it.year ?? ''}';
}

/// 一部作品在所有服务器上的副本
class AggregatedTitle {
  AggregatedTitle(this.copies);

  final List<MediaItem> copies;

  MediaItem get primary => copies.first;
  int get serverCount => copies.map((c) => c.serverId).toSet().length;
}

/// 把条目按"同一部作品"分组（任意一个 ID 相同或标题年份相同即合并），保持原有顺序
List<AggregatedTitle> groupTitles(Iterable<MediaItem> items) {
  final groups = <AggregatedTitle>[];
  for (final it in items) {
    final g = groups.where((g) => g.copies.any((c) => sameTitle(c, it))).firstOrNull;
    if (g == null) {
      groups.add(AggregatedTitle([it]));
    } else if (!g.copies.any((c) => c.serverId == it.serverId && c.id == it.id)) {
      g.copies.add(it);
    }
  }
  return groups;
}
