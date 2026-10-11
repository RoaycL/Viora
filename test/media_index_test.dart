import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/aggregate/tmdb_link.dart';
import 'package:viora/data/aggregate/sources.dart';
import 'package:viora/data/index/media_index.dart';
import 'package:viora/data/index/title_norm.dart';
import 'package:viora/data/media/media_models.dart';

MediaItem movie(String server, String id, String name, {int? year, String? tmdb, String? imdb}) => MediaItem(
  serverId: server,
  id: id,
  kind: MediaKind.movie,
  name: name,
  year: year,
  tmdbId: tmdb,
  imdbId: imdb,
  dateCreated: DateTime(2026, 1, 1),
);

MediaItem series(String server, String id, String name, {int? year, String? tmdb}) =>
    MediaItem(serverId: server, id: id, kind: MediaKind.series, name: name, year: year, tmdbId: tmdb);

void main() {
  test('标题归一化：全角、繁简、年份、季、标点', () {
    expect(normalizeTitle('時光代理人'), normalizeTitle('时光代理人'));
    expect(normalizeTitle('时光代理人 (2021)'), '时光代理人');
    expect(normalizeTitle('时光代理人 第二季'), '时光代理人');
    expect(normalizeTitle('Ｓａｈａｒａ'), 'sahara');
    expect(normalizeTitle('Spider-Man: No Way Home'), 'spidermannowayhome');
    expect(titleInitials('时光代理人'), 'sgdlr');
    expect(titlePinyin('繁花'), 'fanhua');
  });

  test('同一部作品判断', () {
    expect(sameTitle(movie('a', '1', '沙丘', tmdb: '438631'), movie('b', '9', 'Dune', tmdb: '438631')), isTrue);
    // ID 不同即使同名也不是
    expect(sameTitle(movie('a', '1', '沙丘', tmdb: '1'), movie('b', '9', '沙丘', tmdb: '2')), isFalse);
    // 没有 ID 按标题 + 年份（±1）
    expect(sameTitle(movie('a', '1', '繁花', year: 2023), movie('b', '9', '繁花', year: 2024)), isTrue);
    expect(sameTitle(movie('a', '1', '繁花', year: 2010), movie('b', '9', '繁花', year: 2023)), isFalse);
    // 电影和剧集不合并
    expect(sameTitle(movie('a', '1', '繁花'), series('b', '9', '繁花')), isFalse);
  });

  test('索引：写入、拼音搜索、跨服务器匹配、全量同步清理', () async {
    final index = (await MediaIndex.open(path: ':memory:'))!;
    final g = index.beginFull('a');
    index.upsert('a', [
      series('a', 's1', '时光代理人', year: 2021, tmdb: '95479'),
      movie('a', 'm1', '沙丘', year: 2021, tmdb: '438631'),
      movie('a', 'm2', '旧电影', year: 1999),
    ], gen: g);
    index.finishFull('a', g);
    index.upsert('b', [series('b', 's9', '時光代理人', year: 2021), movie('b', 'm9', 'Dune', year: 2021, tmdb: '438631')]);

    expect(index.search('sgdlr').map((e) => e.id), containsAll(['s1', 's9']));
    expect(index.search('shiguang').length, 2);
    expect(index.search('沙丘').single.id, 'm1');
    expect(index.search('dune').single.id, 'm9');

    final dune = index.matches(movie('a', 'm1', '沙丘', year: 2021, tmdb: '438631'));
    expect(dune.map((e) => '${e.serverId}/${e.id}'), containsAll(['a/m1', 'b/m9']));

    // 再次全量同步时 m2 不再出现 → 被删除
    final g2 = index.beginFull('a');
    index.upsert('a', [movie('a', 'm1', '沙丘', year: 2021, tmdb: '438631')], gen: g2);
    index.finishFull('a', g2);
    expect(index.count('a'), 1);
    expect(index.count('b'), 2);

    index.retainServers({'a'});
    expect(index.count('b'), 0);
    index.close();
  });

  test('分组：同一作品合并，保持顺序', () {
    final groups = groupTitles([
      movie('a', '1', '沙丘', tmdb: '438631'),
      movie('a', '2', '繁花', year: 2023),
      movie('b', '9', 'Dune', tmdb: '438631'),
    ]);
    expect(groups.length, 2);
    expect(groups.first.copies.length, 2);
    expect(groups.first.serverCount, 2);
  });

  test('资源排序：偏好服务器 > 分辨率 > 延迟 > 码率', () {
    SourceOption opt(String server, int width, {int? latency, int bitrate = 0}) => SourceOption(
      item: movie(server, 'x', 'x'),
      source: MediaSourceInfo(
        serverId: server,
        itemId: 'x',
        id: '$server-$width',
        container: 'mkv',
        bitrate: bitrate,
        streams: [MediaStreamInfo(index: 0, type: 'Video', width: width, height: width * 9 ~/ 16)],
      ),
      serverName: server,
      latencyMs: latency,
    );
    final ranked = rankSources([
      opt('a', 1920, latency: 50),
      opt('b', 3840, latency: 300),
      opt('c', 3840, latency: 40, bitrate: 1),
    ]);
    expect(ranked.map((o) => o.serverId), ['c', 'b', 'a']);
    expect(rankSources(ranked, preferredServerId: 'a').first.serverId, 'a');
  });

  test('最近入库：新内容多的服务器不会把其他服务器挤掉；剧集按最近更新新集排序', () async {
    final index = (await MediaIndex.open(path: ':memory:'))!;
    MediaItem at(String server, String id, DateTime t, {MediaKind kind = MediaKind.movie, DateTime? newEpisode}) =>
        MediaItem(
          serverId: server,
          id: id,
          kind: kind,
          name: '$server-$id',
          dateCreated: t,
          lastMediaAdded: newEpisode,
        );
    // a：最近一周新增 40 部；b：一个月前的 3 部，外加一部老剧昨天更新了新集
    final now = DateTime(2026, 10, 10);
    index.upsert('a', [for (var i = 0; i < 40; i++) at('a', '$i', now.subtract(Duration(hours: i)))]);
    index.upsert('b', [
      for (var i = 0; i < 3; i++) at('b', '$i', now.subtract(Duration(days: 30 + i))),
      at(
        'b',
        'show',
        DateTime(2024),
        kind: MediaKind.series,
        newEpisode: now.subtract(const Duration(hours: 5, minutes: 30)),
      ),
    ]);
    // 以前只取全局最新：b 一部都排不进前 24
    expect(groupTitles(index.latest(limit: 60)).take(24).where((g) => g.primary.serverId == 'b').length, 1);

    final recent = balancedLatest(index.latestPerServer(perServer: 30));
    expect(recent.length, 24);
    expect(recent.where((g) => g.primary.serverId == 'b').length, 4);
    // 仍按时间倒序：更新了新集的老剧排在第 7 位
    expect(recent[6].primary.id, 'show');
    expect(recent.last.primary.id, '2');
    index.close();
  });

  test('聚合搜索比对：双方都有的 ID 优先，没有 ID 时按中文名 / 原名 + 年份 ±1', () {
    final probe = TitleProbe(kind: MediaKind.movie, titles: ['沙丘', 'Dune'], year: 2021, tmdbId: '438631');
    expect(probe.terms, ['沙丘', 'Dune']);
    expect(probe.matches(movie('b', '1', 'Dune: Part One', tmdb: '438631')), isTrue);
    expect(probe.matches(movie('b', '2', '沙丘', year: 1984, tmdb: '841')), isFalse);
    expect(probe.matches(movie('b', '3', 'Dune', year: 2022)), isTrue);
    expect(probe.matches(movie('b', '4', 'Dune', year: 1984)), isFalse);
    expect(probe.matches(series('b', '5', '沙丘', year: 2021)), isFalse);
  });

  test('服务器默认参与聚合搜索，旧配置没有这个字段也一样', () {
    const s = ServerConfig(id: 'a', type: ServerType.emby, name: 'a', lines: [], username: 'u');
    expect(s.aggregate, isTrue);
    final json = s.toJson()..remove('aggregate');
    expect(ServerConfig.fromJson(json).aggregate, isTrue);
    final off = s.copyWith(aggregate: false);
    expect(ServerConfig.fromJson(off.toJson()).aggregate, isFalse);
    final config = AppConfig(
      servers: [
        s,
        off.copyWith(),
        const ServerConfig(id: 'c', type: ServerType.jellyfin, name: 'c', lines: [], username: 'u', aggregate: false),
      ],
    );
    expect(config.aggregateServerIds, {'a'});
  });
}
