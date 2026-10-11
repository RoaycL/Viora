import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/data/media/server_registry.dart';
import 'package:viora/features/parental/parental_settings_section.dart';

void main() {
  test('分级对应年龄', () {
    expect(ratingAge('G'), 0);
    expect(ratingAge('TV-Y7'), 7);
    expect(ratingAge('PG'), 8);
    expect(ratingAge('PG-13'), 13);
    expect(ratingAge('US-PG-13'), 13);
    expect(ratingAge('TV-MA'), 17);
    expect(ratingAge('R'), 17);
    expect(ratingAge('NC-17'), 18);
    expect(ratingAge('DE-16'), 16);
    expect(ratingAge('FSK-12'), 12);
    expect(ratingAge('KR-19'), 19);
    expect(ratingAge('JP-R18+'), 18);
    expect(ratingAge('NR'), isNull);
    expect(ratingAge(null), isNull);
  });

  test('允许范围：12 岁以下放行 PG、拦 PG-13；没有分级默认放行，打开开关后拦', () {
    const p = ParentalConfig(enabled: true, maxAge: 12);
    expect(p.allows('PG'), isTrue);
    expect(p.allows('TV-PG'), isTrue);
    expect(p.allows('PG-13'), isFalse);
    expect(p.allows('R'), isFalse);
    expect(p.allows(null), isTrue);
    expect(p.copyWith(blockUnrated: true).allows(null), isFalse);
    expect(const ParentalConfig(maxAge: 7).maxOfficialRating, 'G');
    expect(const ParentalConfig(maxAge: 16).maxOfficialRating, 'PG-13');
  });

  test('儿童模式隐藏 R18 服务器，但修改配置、保存时不会丢掉它们', () {
    const normal = ServerConfig(id: 'a', type: ServerType.emby, name: '家里', lines: [], username: 'u');
    const adult = ServerConfig(id: 'b', type: ServerType.emby, name: '另一台', lines: [], username: 'u', adult: true);
    const c = AppConfig(servers: [normal, adult], parental: ParentalConfig(enabled: true));
    expect(c.servers.map((s) => s.id), ['a']);
    expect(c.server('b'), isNull);
    final changed = c.copyWith(tmdb: const TmdbConfig(apiKey: 'k'));
    expect(changed.allServers.map((s) => s.id), ['a', 'b']);
    final back = AppConfig.fromJson(changed.toJson());
    expect(back.allServers.length, 2);
    expect(back.parental.enabled, isTrue);
    expect(back.copyWith(parental: back.parental.copyWith(enabled: false)).servers.length, 2);

    const item = MediaItem(serverId: 'b', id: 'x', kind: MediaKind.movie, name: 'x');
    expect(itemVisible(c, item), isFalse);
    expect(
      itemVisible(c, const MediaItem(serverId: 'a', id: 'y', kind: MediaKind.movie, name: 'y', officialRating: 'R')),
      isFalse,
    );
    expect(
      itemVisible(c, const MediaItem(serverId: 'a', id: 'z', kind: MediaKind.movie, name: 'z', officialRating: 'PG')),
      isTrue,
    );
  });

  test('PIN 只存哈希，不同设备结果不同', () {
    expect(hashPin('1234', 'dev1'), isNot('1234'));
    expect(hashPin('1234', 'dev1'), hashPin('1234', 'dev1'));
    expect(hashPin('1234', 'dev1'), isNot(hashPin('1234', 'dev2')));
  });

  test('儿童模式下请求带 MaxOfficialRating，返回里超龄的再过滤掉', () async {
    final queries = <Map<String, String>>[];
    final fake = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => fake.close(force: true));
    fake.listen((req) async {
      queries.add(req.uri.queryParameters);
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'Items': [
            {'Id': '1', 'Name': '动画', 'Type': 'Movie', 'OfficialRating': 'G'},
            {'Id': '2', 'Name': '恐怖片', 'Type': 'Movie', 'OfficialRating': 'R'},
            {'Id': '3', 'Name': '没分级', 'Type': 'Movie'},
          ],
          'TotalRecordCount': 3,
        }),
      );
      await req.response.close();
    });
    final server = ServerConfig(
      id: 's',
      type: ServerType.jellyfin,
      name: 's',
      lines: [ServerLine(id: 'l', name: 'l', url: 'http://127.0.0.1:${fake.port}')],
      username: 'u',
      userId: 'uid',
      token: 'tok',
    );
    final kids = clientForDraft(
      AppConfig(servers: [server], parental: const ParentalConfig(enabled: true, maxAge: 12)),
      server,
    );
    final page = await kids.items();
    expect(queries.last['MaxOfficialRating'], 'PG');
    expect(page.items.map((i) => i.name), ['动画', '没分级']);

    final normal = clientForDraft(AppConfig(servers: [server]), server);
    final all = await normal.items();
    expect(queries.last.containsKey('MaxOfficialRating'), isFalse);
    expect(all.items.length, 3);
  });
}
