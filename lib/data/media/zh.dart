/// 元数据中文化的本地规则（不依赖网络）：类型、季名等。
library;

/// 文本中是否含有中日韩文字（用来判断是否需要从 TMDB 补中文）
bool hasCjk(String? s) => s != null && RegExp(r'[㐀-鿿豈-﫿]').hasMatch(s);

const _genres = <String, String>{
  'action': '动作',
  'adventure': '冒险',
  'action & adventure': '动作冒险',
  'animation': '动画',
  'anime': '动漫',
  'biography': '传记',
  'comedy': '喜剧',
  'crime': '犯罪',
  'documentary': '纪录',
  'drama': '剧情',
  'family': '家庭',
  'fantasy': '奇幻',
  'film-noir': '黑色电影',
  'film noir': '黑色电影',
  'game-show': '游戏节目',
  'history': '历史',
  'horror': '恐怖',
  'kids': '儿童',
  'music': '音乐',
  'musical': '歌舞',
  'mystery': '悬疑',
  'news': '新闻',
  'reality': '真人秀',
  'reality-tv': '真人秀',
  'romance': '爱情',
  'science fiction': '科幻',
  'sci-fi': '科幻',
  'sci-fi & fantasy': '科幻奇幻',
  'short': '短片',
  'soap': '肥皂剧',
  'sport': '运动',
  'sports': '运动',
  'suspense': '悬疑',
  'talk': '脱口秀',
  'talk-show': '脱口秀',
  'thriller': '惊悚',
  'tv movie': '电视电影',
  'war': '战争',
  'war & politics': '战争政治',
  'western': '西部',
  'disaster': '灾难',
  'martial arts': '武侠',
  'costume': '古装',
  'erotic': '情色',
  'lgbtq': '同性',
  'mini-series': '迷你剧',
  'indie': '独立',
  'holiday': '节日',
};

/// 英文类型名 → 中文；未收录的原样返回
String translateGenre(String genre) => _genres[genre.trim().toLowerCase()] ?? genre;

/// `Season 1` → `第 1 季`，`Specials` → `特别篇`
String localizeSeasonName(String name, int? number) {
  final n = name.trim();
  if (RegExp(r'^specials?$', caseSensitive: false).hasMatch(n) || (number == 0 && !hasCjk(n))) return '特别篇';
  final m = RegExp(r'^season\s*(\d+)$', caseSensitive: false).firstMatch(n);
  if (m != null) return '第 ${int.parse(m[1]!)} 季';
  return n;
}
