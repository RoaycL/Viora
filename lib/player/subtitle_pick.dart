import '../data/config/app_config.dart';
import 'engine.dart';

/// 起播时按设置里的「默认字幕」挑一条字幕轨。
///
/// 返回 `(true, 轨道)` 表示要切换（轨道为 null = 关闭字幕）；`(false, null)` 表示不动，沿用片源自带的默认轨。
/// 设置的语言在片子里找不到时也不动。
(bool, EngineTrack?) pickSubtitle(List<EngineTrack> tracks, SubtitlePreference pref) {
  if (pref == SubtitlePreference.auto) return (false, null);
  if (pref == SubtitlePreference.off) return (true, null);
  EngineTrack? best;
  var bestScore = 0;
  for (final t in tracks) {
    // 内封字幕优先：同分时排在外挂前面
    final score = _score(t, pref) * 2 + (t.external ? 0 : 1);
    if (_score(t, pref) > 0 && score > bestScore) {
      best = t;
      bestScore = score;
    }
  }
  return best == null ? (false, null) : (true, best);
}

final _hantTitle = RegExp(r'繁|cht|big5|traditional|zh[-_ ]?(tw|hk|hant)', caseSensitive: false);
final _hansTitle = RegExp(r'简|chs|gb|simplified|zh[-_ ]?(cn|hans)', caseSensitive: false);
final _zhTitle = RegExp(r'中|chinese|国语|普通话', caseSensitive: false);
final _enTitle = RegExp(r'english|英', caseSensitive: false);

const _zhLangs = {'chi', 'zho', 'zh', 'chs', 'zhs', 'cmn', 'zh-cn', 'zh-hans', 'zh-sg'};
const _hantLangs = {'cht', 'zht', 'zh-tw', 'zh-hk', 'zh-hant', 'zh-mo', 'yue'};
const _enLangs = {'eng', 'en', 'en-us', 'en-gb'};

/// 0 = 不匹配；分越高越贴合
int _score(EngineTrack t, SubtitlePreference pref) {
  final lang = (t.language ?? '').toLowerCase().replaceAll('_', '-');
  final title = t.title ?? '';
  final hant = _hantTitle.hasMatch(title) || _hantLangs.contains(lang);
  final hans = _hansTitle.hasMatch(title);
  final zh = hans || hant || _zhLangs.contains(lang) || _zhTitle.hasMatch(title);
  switch (pref) {
    case SubtitlePreference.zhHans:
      if (hans && !hant) return 4; // 明确写着简体
      if (hans && hant) return 2; // 简繁双语
      if (zh && !hant) return 3; // 只标了中文，按简体算
      return 0;
    case SubtitlePreference.zhHant:
      if (hant && !hans) return 4;
      if (hant && hans) return 2;
      return 0;
    case SubtitlePreference.en:
      final en = _enLangs.contains(lang) || _enTitle.hasMatch(title);
      if (!en) return 0;
      return zh ? 1 : 4; // 中英双语排在纯英文后面
    case SubtitlePreference.auto:
    case SubtitlePreference.off:
      return 0;
  }
}
