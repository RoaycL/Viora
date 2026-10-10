import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/media/zh.dart';

void main() {
  test('类型翻译', () {
    expect(translateGenre('Science Fiction'), '科幻');
    expect(translateGenre('Action & Adventure'), '动作冒险');
    expect(translateGenre('剧情'), '剧情');
    expect(translateGenre('Unknown Genre'), 'Unknown Genre');
  });

  test('季名', () {
    expect(localizeSeasonName('Season 2', 2), '第 2 季');
    expect(localizeSeasonName('Specials', 0), '特别篇');
    expect(localizeSeasonName('第 1 季', 1), '第 1 季');
    expect(localizeSeasonName('Book One: Water', 1), 'Book One: Water');
  });

  test('是否含中文', () {
    expect(hasCjk('时光代理人'), isTrue);
    expect(hasCjk('Sahara'), isFalse);
    expect(hasCjk(null), isFalse);
  });

  test('解析条目时中文化类型与季名', () {
    final client = EmbyClient(
      config: const AppConfig(),
      server: const ServerConfig(id: 's', type: ServerType.jellyfin, name: 's', lines: [], username: ''),
      appVersion: '0',
    );
    final season = client.parseItem({'Id': '1', 'Type': 'Season', 'Name': 'Season 3', 'IndexNumber': 3});
    expect(season.name, '第 3 季');
    final movie = client.parseItem({
      'Id': '2',
      'Type': 'Movie',
      'Name': 'Sahara',
      'Genres': ['Adventure', 'War'],
    });
    expect(movie.genres, ['冒险', '战争']);
  });
}
