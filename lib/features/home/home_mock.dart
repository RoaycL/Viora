import 'package:flutter/widgets.dart';

import '../../ui/widgets/art.dart';

/// M0 阶段的假数据：接入 TMDB 与媒体服务器后由 HomeFeed 用例替换。
@immutable
class MockTitle {
  const MockTitle({
    required this.id,
    required this.title,
    required this.art,
    this.subtitle = '',
    this.year,
    this.rating,
    this.genres = '',
    this.overview = '',
    this.latinTitle,
    this.resources = 0,
    this.progress,
    this.server,
    this.remaining,
    this.badges = const [],
  });

  final String id;
  final String title;
  final String? latinTitle;
  final String subtitle;
  final int? year;
  final double? rating;
  final String genres;
  final String overview;
  final ArtSpec art;

  /// 可用资源数（0 = 媒体库中没有）
  final int resources;

  /// 继续观看
  final double? progress;
  final String? server;
  final String? remaining;
  final List<String> badges;
}

@immutable
class MockPerson {
  const MockPerson(this.name, this.role, this.art);

  final String name;
  final String role;
  final ArtSpec art;
}

@immutable
class MockBrand {
  const MockBrand(this.name, this.art);

  final String name;
  final ArtSpec art;
}

const _overview =
    '在繁华都市的某个角落，有一家叫做"时光照相馆"的小店还在照常营业。'
    '虽然门庭冷落，但它背后其实由两个具有特殊能力的男人——程小时与陆光经营着……';

abstract final class HomeMock {
  static const heroes = <MockTitle>[
    MockTitle(
      id: 'tv-link-click',
      title: '时光代理人',
      latinTitle: 'LINK CLICK',
      subtitle: '剧集',
      year: 2021,
      rating: 8.5,
      genres: '动画 / 科幻 / 悬疑',
      overview: _overview,
      resources: 3,
      badges: ['4K', 'HDR10'],
      art: ArtSpec(Color(0xFF183F63), Color(0xFF2C2766), Color(0xFFB7C6FF), angle: 135),
    ),
    MockTitle(
      id: 'tv-long-season',
      title: '漫长的季节',
      latinTitle: 'THE LONG SEASON',
      subtitle: '剧集',
      year: 2023,
      rating: 9.4,
      genres: '剧情 / 悬疑 / 犯罪',
      overview: '一个跨越十八年的离奇案件，一个困在过去的出租车司机，一段关于命运、家庭与救赎的故事。',
      resources: 2,
      badges: ['4K', 'Dolby Vision'],
      art: ArtSpec(Color(0xFF5A4A2E), Color(0xFF1A140C), Color(0xFFF3D9A0), angle: 140),
    ),
    MockTitle(
      id: 'tv-triassic',
      title: '三叠纪',
      latinTitle: 'TRIASSIC',
      subtitle: '纪录片',
      year: 2025,
      rating: 8.1,
      genres: '纪录 / 自然',
      overview: '回到两亿年前的地球，见证恐龙崛起前夜的生命图景。',
      resources: 1,
      badges: ['1080P'],
      art: ArtSpec(Color(0xFF20414D), Color(0xFF0A1418), Color(0xFF7CC0B0), angle: 150),
    ),
  ];

  static const resume = <MockTitle>[
    MockTitle(
      id: 'r1',
      title: '漫长的季节',
      subtitle: '第1季 · 第6集',
      server: '私服',
      remaining: 'S1E6 · 剩 47 分钟',
      progress: 0.38,
      art: ArtSpec(Color(0xFF5A3A4A), Color(0xFF1B1014), Color(0xFFE7B9A6)),
    ),
    MockTitle(
      id: 'r2',
      title: '三叠纪',
      subtitle: '第1季 · 第3集',
      server: 'FWorks',
      remaining: 'S1E3 · 剩 31 分钟',
      progress: 0.22,
      art: ArtSpec(Color(0xFF20414D), Color(0xFF0A1418), Color(0xFF7CC0B0)),
    ),
    MockTitle(
      id: 'r3',
      title: '法律与秩序',
      subtitle: '第24季 · 第9集',
      server: 'Youno',
      remaining: 'S24E9 · 剩 12 分钟',
      progress: 0.78,
      art: ArtSpec(Color(0xFF3B3A55), Color(0xFF0F0E18), Color(0xFFC3A6FF)),
    ),
    MockTitle(
      id: 'r4',
      title: '生化危机：惩罚',
      subtitle: '电影 · 2012',
      server: 'ChaPanda',
      remaining: '剩 1 小时 04 分',
      progress: 0.30,
      art: ArtSpec(Color(0xFF5A2B16), Color(0xFF120806), Color(0xFFFF9B5C)),
    ),
    MockTitle(
      id: 'r5',
      title: '凸变英雄 X',
      subtitle: '第1季 · 第2集',
      server: '私服',
      remaining: 'S1E2 · 剩 18 分钟',
      progress: 0.55,
      art: ArtSpec(Color(0xFF3A1F5C), Color(0xFF0D0717), Color(0xFFFF7AD9)),
    ),
    MockTitle(
      id: 'r6',
      title: '时光代理人',
      subtitle: '第1季 · 第3集',
      server: 'ChaPanda',
      remaining: 'S1E3 · 剩 12 分钟',
      progress: 0.45,
      art: ArtSpec(Color(0xFF3C3C7A), Color(0xFF0E0E22), Color(0xFFB9B2FF)),
    ),
  ];

  /// 按 id 查找（详情页用）。海报行的 id 形如 `seed-index`，可确定性地重建。
  static MockTitle? find(String id) {
    for (final t in [...heroes, ...resume]) {
      if (t.id == id) return t;
    }
    final dash = id.lastIndexOf('-');
    final index = dash > 0 ? int.tryParse(id.substring(dash + 1)) : null;
    if (index == null || index < 0 || index > 100) return null;
    return posters(id.substring(0, dash), index + 1)[index];
  }

  static List<MockTitle> posters(String seed, int count) {
    const palette = <ArtSpec>[
      ArtSpec(Color(0xFF2E5C8A), Color(0xFF0C1626), Color(0xFFC9D6FF)),
      ArtSpec(Color(0xFF7A4A2E), Color(0xFF1E120A), Color(0xFFFFD9A8)),
      ArtSpec(Color(0xFF5A3C8A), Color(0xFF120C22), Color(0xFFF2C4FF)),
      ArtSpec(Color(0xFF2E6A5C), Color(0xFF0A1A16), Color(0xFF9FE3C8)),
      ArtSpec(Color(0xFF6A2E4A), Color(0xFF1A0A12), Color(0xFFFF9FC4)),
      ArtSpec(Color(0xFF3A4A4A), Color(0xFF0E1414), Color(0xFFA8C8C0)),
      ArtSpec(Color(0xFF5A2B16), Color(0xFF120806), Color(0xFFFF9B5C)),
      ArtSpec(Color(0xFF20414D), Color(0xFF0A1418), Color(0xFF7CC0B0)),
    ];
    const names = <String>[
      '沙丘：预言',
      '漫长的季节',
      '繁花',
      '三体',
      '奥本海默',
      '狂飙',
      '流浪地球 2',
      '葬送的芙莉莲',
      '我的阿勒泰',
      '庆余年 第二季',
      '周处除三害',
      '热辣滚烫',
    ];
    final offset = seed.codeUnits.fold<int>(0, (a, b) => a + b);
    return List<MockTitle>.generate(count, (i) {
      final k = (i + offset) % names.length;
      return MockTitle(
        id: '$seed-$i',
        title: names[k],
        year: 2020 + (k % 6),
        rating: 7.0 + (k % 25) / 10,
        resources: (i + offset) % 4 == 0 ? 0 : 1 + (i % 3),
        art: palette[(i + offset) % palette.length],
      );
    });
  }

  static const people = <MockPerson>[
    MockPerson('李豪凌', '导演', ArtSpec(Color(0xFF8A6A5A), Color(0xFF2A1E18), Color(0xFFF2D2C0))),
    MockPerson('苏尚卿', '配音', ArtSpec(Color(0xFF5A6A8A), Color(0xFF181E2A), Color(0xFFD0DCF2))),
    MockPerson('杨天翔', '配音', ArtSpec(Color(0xFF6A6A6A), Color(0xFF1A1A1A), Color(0xFFE0E0E0))),
    MockPerson('李诗萌', '配音', ArtSpec(Color(0xFF8A5A6A), Color(0xFF2A181E), Color(0xFFF2C8D6))),
    MockPerson('张译', '演员', ArtSpec(Color(0xFF5A5A3A), Color(0xFF1A1A10), Color(0xFFE6E0B0))),
    MockPerson('周迅', '演员', ArtSpec(Color(0xFF6A3A3A), Color(0xFF1E1010), Color(0xFFF0B8B8))),
    MockPerson('雷佳音', '演员', ArtSpec(Color(0xFF3A5A6A), Color(0xFF10181E), Color(0xFFB0D8F0))),
    MockPerson('赵丽颖', '演员', ArtSpec(Color(0xFF6A4A6A), Color(0xFF1E141E), Color(0xFFF0C8F0))),
  ];

  static const platforms = <MockBrand>[
    MockBrand('Netflix', ArtSpec(Color(0xFF3A0A0C), Color(0xFF0A0202), Color(0xFFE50914))),
    MockBrand('Disney+', ArtSpec(Color(0xFF0B1C4A), Color(0xFF040A1C), Color(0xFF3B6CFF))),
    MockBrand('HBO', ArtSpec(Color(0xFF2A2A2A), Color(0xFF0A0A0A), Color(0xFF9A9AFF))),
    MockBrand('Apple TV+', ArtSpec(Color(0xFF2A2A2E), Color(0xFF0A0A0C), Color(0xFFDADADF))),
    MockBrand('Bilibili', ArtSpec(Color(0xFF0A3A4A), Color(0xFF03121A), Color(0xFF23ADE5))),
    MockBrand('腾讯视频', ArtSpec(Color(0xFF0A3A2A), Color(0xFF03120C), Color(0xFFFF8A1F))),
  ];
}
