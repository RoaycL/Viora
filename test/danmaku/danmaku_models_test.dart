import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/danmaku/danmaku_models.dart';
import 'package:viora/features/danmaku/danmaku_service.dart';

void main() {
  group('parseComments', () {
    test('弹弹play 格式与 B 站 8 段格式', () {
      final list = parseComments({
        'count': 4,
        'comments': [
          {'cid': 1, 'p': '12.5,1,16777215,[youku]', 'm': '第二条'},
          {'cid': 2, 'p': '3.00,5,16711680,[qq]', 'm': '顶部 红色'},
          {'cid': 3, 'p': '8.0,4,25,65280,1700000000,0,abc,123', 'm': '底部绿色'},
          {'cid': 4, 'p': 'x,1,1', 'm': '坏数据'},
          {'cid': 5, 'p': '1,1,1', 'm': '   '},
        ],
      });
      expect(list.map((c) => c.text), ['顶部 红色', '底部绿色', '第二条']);
      expect(list[0].mode, DanmakuMode.top);
      expect(list[0].color, 0xFF0000);
      expect(list[1].mode, DanmakuMode.bottom);
      expect(list[1].color, 65280);
      expect(list[2].mode, DanmakuMode.scroll);
      expect(list[2].time, 12.5);
    });
  });

  group('processComments', () {
    final input = [for (var i = 0; i < 100; i++) DanmakuComment(time: i.toDouble(), text: i.isEven ? '好看$i' : '剧透$i')];

    test('屏蔽词', () {
      final out = processComments(input, blockWords: splitKeywords('剧透， 无关'));
      expect(out.length, 50);
      expect(out.every((c) => c.text.startsWith('好看')), isTrue);
    });

    test('数量上限：随机剔除后仍按时间排序', () {
      final out = processComments(input, maxCount: 30, random: Random(1));
      expect(out.length, 30);
      for (var i = 1; i < out.length; i++) {
        expect(out[i].time >= out[i - 1].time, isTrue);
      }
    });

    test('颜色模式', () {
      final colored = [for (var i = 0; i < 50; i++) DanmakuComment(time: 0, text: 'a', color: 0x123456)];
      expect(processComments(colored, colorMode: DanmakuColorMode.white).every((c) => c.color == 0xFFFFFF), isTrue);
      expect(
        processComments(colored, colorMode: DanmakuColorMode.all).every((c) => danmakuPalette.contains(c.color)),
        isTrue,
      );
      final partial = processComments(colored, colorMode: DanmakuColorMode.partial, random: Random(3));
      expect(partial.any((c) => c.color == 0xFFFFFF), isTrue);
      expect(partial.any((c) => c.color != 0xFFFFFF), isTrue);
    });

    test('繁简转换', () {
      final out = processComments(const [DanmakuComment(time: 0, text: '這個劇真好看')], convert: DanmakuConvert.t2s);
      expect(out.single.text, '这个剧真好看');
    });
  });

  group('匹配', () {
    test('中文数字', () {
      expect(convertChineseNumber('三'), 3);
      expect(convertChineseNumber('十'), 10);
      expect(convertChineseNumber('十二'), 12);
      expect(convertChineseNumber('二十'), 20);
      expect(convertChineseNumber('二十三'), 23);
      expect(convertChineseNumber('一百二十'), 120);
      expect(convertChineseNumber('叁'), 3);
      expect(convertChineseNumber('12'), 12);
    });

    test('季匹配', () {
      expect(matchSeason('凡人修仙传(2025)【国产剧】from youku', '凡人修仙传', 1), isTrue);
      expect(matchSeason('凡人修仙传(2025)【国产剧】from youku', '凡人修仙传', 2), isFalse);
      expect(matchSeason('庆余年 第二季(2024)【电视剧】from qq', '庆余年', 2), isTrue);
      expect(matchSeason('庆余年2(2024)', '庆余年', 2), isTrue);
      expect(matchSeason('庆余年 第二季(2024)', '庆余年', 1), isFalse);
      expect(matchSeason('古惑仔3之只手遮天', '遮天', 1), isFalse);
    });

    test('搜索结果排序与屏蔽', () {
      DanmakuAnime a(int id, String title, [String type = '电视剧']) =>
          DanmakuAnime(server: 's', animeId: id, title: title, type: type);
      final ranked = rankAnimes(
        [a(1, '庆余年(2019)'), a(2, '庆余年 第二季(2024)'), a(3, '庆余年 解说版(2024)'), a(4, '另一个(2020)')],
        '庆余年',
        season: 2,
        blockWords: ['解说'],
      );
      expect(ranked.map((x) => x.animeId), [2, 1, 4]);
      final movie = rankAnimes([a(1, '沙丘 解说(2021)', '电视剧'), a(2, '沙丘(2021)', '电影')], '沙丘', movie: true);
      expect(movie.first.animeId, 2);
    });

    test('按集数选集', () {
      final eps = [
        for (var i = 1; i <= 5; i++) DanmakuEpisode(server: 's', episodeId: 100 + i, title: '第$i集', number: i + 10),
      ];
      expect(pickEpisode(eps, 12)?.episodeId, 102);
      expect(pickEpisode(eps, 3)?.episodeId, 103);
      expect(pickEpisode(eps, 9), isNull);
      expect(pickEpisode(eps, 0), isNull);
    });

    test('自动匹配用的文件名', () {
      const t = DanmakuTarget(title: '凡人修仙传', key: 'k', season: 1, episode: 2);
      expect(t.fileName, '凡人修仙传 S01E02');
      const m = DanmakuTarget(title: '沙丘', key: 'k', movie: true);
      expect(m.fileName, '沙丘');
    });
  });

  group('DanmakuConfig', () {
    test('服务器地址规范化', () {
      expect(DanmakuConfig.normalizeServer(' danmu.example.com/abc/ '), 'https://danmu.example.com/abc');
      expect(DanmakuConfig.normalizeServer('192.168.1.10:9321/87654321'), 'http://192.168.1.10:9321/87654321');
      expect(DanmakuConfig.normalizeServer('nas:9321/token'), 'http://nas:9321/token');
      expect(DanmakuConfig.normalizeServer('http://a.com/t//'), 'http://a.com/t');
      expect(DanmakuConfig.normalizeServer('  '), '');
    });

    test('序列化', () {
      const c = DanmakuConfig(
        servers: ['https://a.com/t', ''],
        maxCount: 0,
        fontSize: 40,
        convert: DanmakuConvert.t2s,
        colorMode: DanmakuColorMode.partial,
        blockWords: '剧透',
      );
      final back = AppConfig.fromJson(AppConfig(danmaku: c).toJson()).danmaku;
      expect(back.servers, c.servers);
      expect(back.activeServers, ['https://a.com/t']);
      expect(back.maxCount, 0);
      expect(back.fontSize, 40);
      expect(back.convert, DanmakuConvert.t2s);
      expect(back.colorMode, DanmakuColorMode.partial);
      expect(back.blockWords, '剧透');
      expect(AppConfig.fromJson(const {}).danmaku.enabled, isTrue);
    });
  });
}
