import 'package:lpinyin/lpinyin.dart';

/// 规范化结果缓存：繁简转换、正则都不便宜，分组时同一个片名会被反复规范化
final _normCache = <String, String>{};

/// 标题归一化（docs/04-aggregation.md §3）：
/// 全角转半角、繁转简、小写、去掉标点空白、去掉"第X季""(2021)"等后缀，用于跨服务器匹配同一部作品。
String normalizeTitle(String title) {
  final hit = _normCache[title];
  if (hit != null) return hit;
  final result = _normalize(title);
  if (_normCache.length >= 20000) _normCache.clear();
  _normCache[title] = result;
  return result;
}

String _normalize(String title) {
  var s = title.trim();
  // 全角 → 半角
  s = String.fromCharCodes(
    s.runes.map((c) {
      if (c == 0x3000) return 0x20;
      if (c >= 0xFF01 && c <= 0xFF5E) return c - 0xFEE0;
      return c;
    }),
  );
  // 繁体 → 简体，让"時光代理人"和"时光代理人"能匹配
  try {
    s = ChineseHelper.convertToSimplifiedChinese(s);
  } catch (_) {}
  s = s.toLowerCase();
  s = s.replaceAll(RegExp(r'[\(\[（【]\s*\d{4}\s*[\)\]）】]'), ''); // (2021)
  s = s.replaceAll(RegExp(r'第\s*[0-9一二三四五六七八九十]+\s*[季部]'), '');
  s = s.replaceAll(RegExp(r'\bseason\s*\d+\b'), '');
  s = s.replaceAll(RegExp(r'[\s\p{P}\p{S}]+', unicode: true), '');
  return s;
}

/// 拼音首字母（搜索用）：`时光代理人` → `sgdlr`；英文保留字母数字
String titleInitials(String title) {
  try {
    return PinyinHelper.getShortPinyin(title).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  } catch (_) {
    return '';
  }
}

/// 全拼（搜索用）：`时光代理人` → `shiguangdailiren`
String titlePinyin(String title) {
  try {
    return PinyinHelper.getPinyinE(
      title,
      separator: '',
      defPinyin: '',
    ).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  } catch (_) {
    return '';
  }
}
