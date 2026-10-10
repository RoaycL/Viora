import 'package:flutter_test/flutter_test.dart';
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
}
