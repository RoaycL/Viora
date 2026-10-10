import 'dart:math';

import 'package:lpinyin/lpinyin.dart';

/// 弹幕（弹弹play 兼容接口，自部署项目 huangxd-/danmu_api）。设计见 docs/10-danmaku.md。

enum DanmakuMode { scroll, top, bottom }

/// 一条弹幕
class DanmakuComment {
  const DanmakuComment({required this.time, required this.text, this.mode = DanmakuMode.scroll, this.color = 0xFFFFFF});

  /// 出现时间（秒，相对视频开头）
  final double time;
  final String text;
  final DanmakuMode mode;

  /// RGB（不含透明度）
  final int color;

  DanmakuComment copyWith({String? text, int? color}) =>
      DanmakuComment(time: time, text: text ?? this.text, mode: mode, color: color ?? this.color);
}

/// 搜索到的作品（某个弹幕服务器上的 animeId）
class DanmakuAnime {
  const DanmakuAnime({
    required this.server,
    required this.animeId,
    required this.title,
    this.type = '',
    this.episodeCount,
  });

  final String server;
  final int animeId;
  final String title;
  final String type;
  final int? episodeCount;

  factory DanmakuAnime.fromJson(String server, Map<String, dynamic> j) => DanmakuAnime(
    server: server,
    animeId: _int(j['animeId']) ?? 0,
    title: j['animeTitle'] as String? ?? '',
    type: j['typeDescription'] as String? ?? j['type'] as String? ?? '',
    episodeCount: _int(j['episodeCount']),
  );
}

class DanmakuEpisode {
  const DanmakuEpisode({required this.server, required this.episodeId, required this.title, this.number});

  final String server;
  final int episodeId;
  final String title;
  final int? number;

  factory DanmakuEpisode.fromJson(String server, Map<String, dynamic> j) => DanmakuEpisode(
    server: server,
    episodeId: _int(j['episodeId']) ?? 0,
    title: j['episodeTitle'] as String? ?? '',
    number: _int(j['episodeNumber']),
  );
}

/// 一集的弹幕和它的来源
class DanmakuTrack {
  const DanmakuTrack({required this.comments, required this.source, required this.server, required this.episodeId});

  final List<DanmakuComment> comments;

  /// 来源说明，如「凡人修仙传(2025)【国产剧】from youku · 第2集」
  final String source;
  final String server;
  final int episodeId;
}

int? _int(Object? v) => switch (v) {
  int i => i,
  num n => n.toInt(),
  String s => int.tryParse(s.trim()),
  _ => null,
};

// ───────────────────────── 解析 ─────────────────────────

/// 解析 `/api/v2/comment` 的返回。`p` 为「时间,模式,颜色,…」；
/// 8 段以上是 B 站格式「时间,模式,字号,颜色,…」。模式 4 = 底部，5 = 顶部，其余滚动。
List<DanmakuComment> parseComments(Map<String, dynamic> json) {
  final list = json['comments'] as List? ?? const [];
  final out = <DanmakuComment>[];
  for (final c in list) {
    if (c is! Map) continue;
    final text = (c['m'] ?? c['message'])?.toString().trim() ?? '';
    final p = c['p']?.toString() ?? '';
    if (text.isEmpty || p.isEmpty) continue;
    final parts = p.split(',');
    final time = double.tryParse(parts[0]);
    if (time == null || time < 0) continue;
    final mode = parts.length > 1 ? int.tryParse(parts[1]) ?? 1 : 1;
    final colorIndex = parts.length >= 8 ? 3 : 2;
    final color = parts.length > colorIndex ? int.tryParse(parts[colorIndex]) ?? 0xFFFFFF : 0xFFFFFF;
    out.add(
      DanmakuComment(
        time: time,
        text: text.replaceAll(RegExp(r'\s+'), ' '),
        mode: switch (mode) {
          4 => DanmakuMode.bottom,
          5 => DanmakuMode.top,
          _ => DanmakuMode.scroll,
        },
        color: color & 0xFFFFFF,
      ),
    );
  }
  out.sort((a, b) => a.time.compareTo(b.time));
  return out;
}

// ───────────────────────── 过滤 ─────────────────────────

enum DanmakuConvert {
  none('保持原样'),
  t2s('转简体'),
  s2t('转繁体');

  const DanmakuConvert(this.label);
  final String label;

  static DanmakuConvert parse(String? s) => values.firstWhere((e) => e.name == s, orElse: () => none);
}

enum DanmakuColorMode {
  none('保持原样'),
  white('全部纯白'),
  partial('部分彩色'),
  all('全部彩色');

  const DanmakuColorMode(this.label);
  final String label;

  static DanmakuColorMode parse(String? s) => values.firstWhere((e) => e.name == s, orElse: () => none);
}

/// 彩色弹幕的调色板（红、黄、橙、粉、紫、浅蓝、浅绿）
const danmakuPalette = [16711680, 16776960, 16752384, 16738740, 13445375, 11730943, 11730790];

/// 逗号（中英文）分隔的关键词
List<String> splitKeywords(String s) =>
    s.split(RegExp('[,，]')).map((k) => k.trim()).where((k) => k.isNotEmpty).toList();

/// 繁简转换、屏蔽词、数量上限（按全片等比例随机剔除）、颜色
List<DanmakuComment> processComments(
  List<DanmakuComment> input, {
  DanmakuConvert convert = DanmakuConvert.none,
  List<String> blockWords = const [],
  int maxCount = 0,
  DanmakuColorMode colorMode = DanmakuColorMode.none,
  Random? random,
}) {
  final rnd = random ?? Random();
  var list = input;
  if (convert != DanmakuConvert.none) {
    list = [
      for (final c in list)
        c.copyWith(
          text: convert == DanmakuConvert.t2s
              ? ChineseHelper.convertToSimplifiedChinese(c.text)
              : ChineseHelper.convertToTraditionalChinese(c.text),
        ),
    ];
  }
  if (blockWords.isNotEmpty) {
    list = [
      for (final c in list)
        if (!blockWords.any(c.text.contains)) c,
    ];
  }
  if (maxCount > 0 && list.length > maxCount) {
    list = [...list]..shuffle(rnd);
    list = list.sublist(0, maxCount)..sort((a, b) => a.time.compareTo(b.time));
  }
  if (colorMode != DanmakuColorMode.none) {
    int pick() => danmakuPalette[rnd.nextInt(danmakuPalette.length)];
    list = [
      for (final c in list)
        c.copyWith(
          color: switch (colorMode) {
            DanmakuColorMode.white => 0xFFFFFF,
            DanmakuColorMode.partial => rnd.nextBool() ? pick() : 0xFFFFFF,
            _ => pick(),
          },
        ),
    ];
  }
  return list;
}

// ───────────────────────── 匹配 ─────────────────────────

/// 中文数字转整数：「十二」→ 12，「二十」→ 20，「叁」→ 3；阿拉伯数字直接转换
int convertChineseNumber(String s) {
  if (RegExp(r'^\d+$').hasMatch(s)) return int.parse(s);
  const digits = {
    '零': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9, //
    '壹': 1, '贰': 2, '貳': 2, '叁': 3, '參': 3, '肆': 4, '伍': 5, '陆': 6, '陸': 6, '柒': 7, '捌': 8, '玖': 9,
  };
  const units = {'十': 10, '百': 100, '千': 1000, '拾': 10, '佰': 100, '仟': 1000};
  var result = 0, current = 0, lastUnit = 1;
  for (final ch in s.split('')) {
    if (digits.containsKey(ch)) {
      current = digits[ch]!;
    } else if (units.containsKey(ch)) {
      final unit = units[ch]!;
      if (current == 0) current = 1;
      if (unit >= lastUnit) {
        result = (result + current) * unit;
      } else {
        result += current * unit;
      }
      lastUnit = unit;
      current = 0;
    }
  }
  return result + current;
}

/// 作品标题是否是要找的那一季：「凡人修仙传」第 1 季匹配「凡人修仙传(2025)」，
/// 第 2 季匹配「凡人修仙传 第二季」「凡人修仙传2」
bool matchSeason(String animeTitle, String query, int season) {
  final title = animeTitle.split(RegExp(r'[(（【]')).first.trim();
  if (!title.startsWith(query)) return false;
  final after = title.substring(query.length).trim();
  if (after.isEmpty) return season == 1;
  final n = RegExp(r'\d+').firstMatch(after);
  if (n != null && int.parse(n[0]!) == season) return true;
  final zh = RegExp('[零一二两三四五六七八九十壹贰貳叁參肆伍陆陸柒捌玖拾]+').firstMatch(after);
  return zh != null && convertChineseNumber(zh[0]!) == season;
}

/// 搜索结果排序：要找的那一季排前面；屏蔽词命中的去掉
List<DanmakuAnime> rankAnimes(
  List<DanmakuAnime> animes,
  String query, {
  int? season,
  bool movie = false,
  List<String> blockWords = const [],
}) {
  final list = [
    for (final a in animes)
      if (a.title.isNotEmpty && !blockWords.any(a.title.contains)) a,
  ];
  int score(DanmakuAnime a) {
    final title = a.title.split(RegExp(r'[(（【]')).first.trim();
    if (movie) {
      final isMovie = a.type.contains('电影') || a.title.contains('电影');
      return (title == query ? 2 : 0) + (isMovie ? 1 : 0);
    }
    if (season != null && matchSeason(a.title, query, season)) return 3;
    return title == query ? 1 : 0;
  }

  final scored = [for (var i = 0; i < list.length; i++) (list[i], score(list[i]), i)];
  scored.sort((a, b) => a.$2 != b.$2 ? b.$2.compareTo(a.$2) : a.$3.compareTo(b.$3));
  return [for (final s in scored) s.$1];
}

/// 按集数选一集：先找 episodeNumber 相同的，再按顺序取第 n 个
DanmakuEpisode? pickEpisode(List<DanmakuEpisode> episodes, int number) {
  if (number <= 0 || episodes.isEmpty) return null;
  for (final e in episodes) {
    if (e.number == number) return e;
  }
  return number <= episodes.length ? episodes[number - 1] : null;
}
