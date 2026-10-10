// TMDB 联调测试（默认跳过）：
//   VIORA_LIVE=1 VIORA_TMDB_TOKEN=<读取令牌> flutter test test/live/tmdb_live_test.dart
// 可选 VIORA_PROXY=<反向代理完整地址> 同时测试经反代访问。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/tmdb/tmdb_client.dart';

void main() {
  final env = Platform.environment;
  final token = env['VIORA_TMDB_TOKEN'] ?? '';
  final skip = env['VIORA_LIVE'] == '1' && token.isNotEmpty ? false : '需要 VIORA_LIVE=1 与 VIORA_TMDB_TOKEN';
  final proxy = env['VIORA_PROXY'] ?? '';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TmdbClient.clearMemoryCache();
  });

  for (final viaProxy in [false, if (proxy.isNotEmpty) true]) {
    test(
      'TMDB 首页各行与详情${viaProxy ? '（经反向代理）' : ''}',
      () async {
        final client = TmdbClient(
          TmdbConfig(apiKey: token, useProxy: viaProxy),
          ProxyConfig(baseUrl: viaProxy ? proxy : ''),
        );
        for (final row in TmdbRow.values) {
          final items = await client.row(row);
          // ignore: avoid_print
          print('$row: ${items.length} 条，例如 ${items.take(3).map((t) => t.title).join('、')}');
          if (row != TmdbRow.animeToday) expect(items, isNotEmpty, reason: '$row');
        }
        final trending = await client.row(TmdbRow.trendingDay);
        expect(trending.first.title, isNotEmpty);
        expect(trending.first.genreNames, isNotEmpty);

        final fightClub = (await client.title(false, 550))!;
        expect(fightClub.title, '搏击俱乐部');
        expect(fightClub.cast, isNotEmpty);
        expect(fightClub.recommendations, isNotEmpty);
        expect(fightClub.logoPath, isNotNull);

        final tv = (await client.title(true, 1399))!; // 权力的游戏
        expect(tv.seasons, greaterThan(5));
        expect(tv.cast, isNotEmpty);

        final (person, credits) = await client.person(819);
        expect(person!.name, isNotEmpty);
        expect(credits, isNotEmpty);

        expect(await client.network(213), isNotEmpty);
        expect(await client.popularPeople(), isNotEmpty);

        final img = client.image(fightClub.posterPath!, size: 'w342');
        if (viaProxy) expect(img, startsWith(proxy));
        final r = await Dio().get<dynamic>(img, options: Options(responseType: ResponseType.bytes));
        expect(r.statusCode, 200);
      },
      skip: skip,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
