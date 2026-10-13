import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' if (dart.library.js_interop) 'sqlite_stub.dart';

import '../media/media_models.dart';
import 'title_norm.dart';

/// 一行索引：item_id, kind, name, norm, initials, pinyin, year, tmdb, imdb, tvdb, created, json
typedef IndexRow = List<Object?>;

String? _blankToNull(String? s) => s == null || s.trim().isEmpty ? null : s.trim();

/// 算出要写入索引的行（纯计算，可以交给 `compute` 在后台 isolate 里跑，避免同步时卡住界面）
List<IndexRow> prepareIndexRows(List<MediaItem> items) => [
  for (final it in items)
    if (it.kind == MediaKind.movie || it.kind == MediaKind.series)
      [
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
        it.addedAt?.millisecondsSinceEpoch,
        jsonEncode(it.toIndexJson()),
      ],
];

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
      CREATE TABLE IF NOT EXISTS index_accounts(
        server_id TEXT PRIMARY KEY,
        scope TEXT NOT NULL
      );
    ''');
    // v2：索引多了剧集的 DateLastMediaAdded（最近入库按新集排序）→ 下次同步时每台服务器全量重建一次
    final version = _db.select('PRAGMA user_version').first['user_version'] as int;
    if (version < 2) {
      _db.execute('UPDATE sync_state SET full_at = NULL');
      _db.execute('PRAGMA user_version = 2');
    }
  }

  final Database _db;
  bool _closed = false;
  bool get isClosed => _closed;

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

  void close() {
    if (_closed) return;
    _closed = true;
    _db.close();
  }

  /// 旧索引没有账号信息：首次绑定时清理该来源，再全量重建；换账号 / 后端同样处理。
  void bindAccounts(Map<String, String> accounts) {
    final previous = {
      for (final row in _db.select('SELECT server_id, scope FROM index_accounts'))
        row['server_id'] as String: row['scope'] as String,
    };
    _db.execute('BEGIN');
    try {
      final known = {
        ...previous.keys,
        ...accounts.keys,
        for (final r in _db.select('SELECT DISTINCT server_id FROM items')) r['server_id'] as String,
        for (final r in _db.select('SELECT server_id FROM sync_state')) r['server_id'] as String,
      };
      for (final id in known) {
        if (accounts[id] != previous[id] || !accounts.containsKey(id)) removeServer(id);
      }
      for (final entry in accounts.entries) {
        _db.execute('INSERT OR REPLACE INTO index_accounts(server_id, scope) VALUES (?, ?)', [entry.key, entry.value]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  bool hasAccount(String serverId, String scope) =>
      !_closed &&
      _db.select('SELECT scope FROM index_accounts WHERE server_id = ?', [serverId]).firstOrNull?['scope'] == scope;

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
  void upsert(String serverId, List<MediaItem> items, {int? gen}) =>
      upsertPrepared(serverId, prepareIndexRows(items), gen: gen);

  /// 写入 [prepareIndexRows] 算好的行（标题归一化、拼音、JSON 可以放到后台 isolate 里算，这里只写库）
  void upsertPrepared(String serverId, List<IndexRow> rows, {int? gen}) {
    if (rows.isEmpty) return;
    final g = gen ?? syncState(serverId).gen;
    final stmt = _db.prepare('''
      INSERT OR REPLACE INTO items(server_id, item_id, kind, name, norm, initials, pinyin, year, tmdb, imdb, tvdb, created, gen, json)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''');
    _db.execute('BEGIN');
    try {
      for (final r in rows) {
        stmt.execute([serverId, ...r.sublist(0, 11), g, r[11]]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      stmt.close();
    }
  }

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
    _db.execute('DELETE FROM index_accounts WHERE server_id = ?', [serverId]);
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

  /// 每台服务器各自最新的 [perServer] 条（按入库时间倒序）。
  /// 合并时不能只取全局最新：新内容多的服务器会把其他服务器挤出「最近入库」
  List<MediaItem> latestPerServer({int perServer = 30}) => _db
      .select(
        '''SELECT * FROM (
             SELECT *, ROW_NUMBER() OVER (PARTITION BY server_id ORDER BY created DESC) AS rn FROM items
           ) WHERE rn <= ? ORDER BY created DESC''',
        [perServer],
      )
      .map(_row)
      .toList();
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

/// 「最近入库」：所有服务器合并、同一部作品只出现一次，按入库时间倒序取 [limit] 部；
/// 每台服务器先保证最多 [limit] / 服务器数 部的名额，名额用不完再由其他服务器补上，
/// 这样新内容多的服务器不会把其他服务器挤掉
List<AggregatedTitle> balancedLatest(List<MediaItem> newestFirst, {int limit = 24}) {
  final groups = groupTitles(newestFirst);
  final servers = {for (final g in groups) g.primary.serverId};
  if (servers.length <= 1) return groups.take(limit).toList();
  final quota = (limit / servers.length).ceil();
  final used = <String, int>{};
  final picked = <AggregatedTitle>{};
  for (final g in groups) {
    if (picked.length >= limit) break;
    final s = g.primary.serverId;
    if ((used[s] ?? 0) >= quota) continue;
    used[s] = (used[s] ?? 0) + 1;
    picked.add(g);
  }
  for (final g in groups) {
    if (picked.length >= limit) break;
    picked.add(g);
  }
  // 保持按时间倒序
  return [
    for (final g in groups)
      if (picked.contains(g)) g,
  ];
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

/// 把条目按"同一部作品"分组（任意一个 ID 相同或标题年份相同即合并），保持原有顺序。
///
/// 先按 ID / 规范化标题建索引，只和可能是同一部的分组比较。原来是每条和所有分组两两比较，
/// 16 台服务器的搜索结果、最近入库（几百到上千条）要比较几十万次，电视上界面线程卡死几十秒、被系统杀掉
List<AggregatedTitle> groupTitles(Iterable<MediaItem> items) {
  final groups = <AggregatedTitle>[];
  final byKey = <String, List<AggregatedTitle>>{};
  final seen = <AggregatedTitle, Set<String>>{};
  for (final it in items) {
    final keys = _matchKeys(it);
    AggregatedTitle? g;
    search:
    for (final k in keys) {
      for (final candidate in byKey[k] ?? const <AggregatedTitle>[]) {
        if (candidate.copies.any((c) => sameTitle(c, it))) {
          g = candidate;
          break search;
        }
      }
    }
    if (g == null) {
      g = AggregatedTitle([it]);
      groups.add(g);
      seen[g] = {'${it.serverId}/${it.id}'};
    } else if (seen[g]!.add('${it.serverId}/${it.id}')) {
      g.copies.add(it);
    } else {
      continue;
    }
    for (final k in keys) {
      final list = byKey.putIfAbsent(k, () => []);
      if (!list.contains(g)) list.add(g);
    }
  }
  return groups;
}

/// 能和 [it] 判为同一部的条目一定至少共享其中一个键（[sameTitle]：ID 相同，或标题相同）
List<String> _matchKeys(MediaItem it) {
  final k = it.kind.index;
  String? id(String? v) => v == null || v.trim().isEmpty ? null : v.trim();
  return [
    if (id(it.tmdbId) case final v?) 't$k:$v',
    if (id(it.imdbId) case final v?) 'i$k:$v',
    if (id(it.tvdbId) case final v?) 'v$k:$v',
    'n$k:${normalizeTitle(it.name)}',
  ];
}
