import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/media/media_models.dart';
import '../../data/tmdb/tmdb_client.dart';
import '../../ui/rows/cards.dart';
import '../../ui/widgets/server_image.dart';
import '../../ui/widgets/tmdb_image.dart';

/// 打开 TMDB 条目的详情页。首页、推荐行只做展示，进详情页后才到各服务器搜索资源（docs/04-aggregation.md §5）
void openTmdbTitle(BuildContext context, TmdbTitle t) => context.push('/tmdb/${t.type}/${t.id}');

/// 播放 TMDB 条目：电影直接播放（默认资源），剧集进详情选集
void playTmdbTitle(BuildContext context, MediaItem copy) {
  if (copy.kind == MediaKind.movie) {
    context.push('/play/${copy.serverId}/${copy.id}?pos=0');
  } else {
    context.push('/item/${copy.serverId}/${copy.id}');
  }
}

String tmdbSubtitle(TmdbTitle t) => [
  if (t.year != null) '${t.year}',
  if (t.rating != null) '★ ${t.rating!.toStringAsFixed(1)}',
  if (t.year == null && t.rating == null) t.isTv ? '剧集' : '电影',
].join(' · ');

/// TMDB 海报卡（只做展示，不查媒体库资源）
class TmdbPosterCard extends StatelessWidget {
  const TmdbPosterCard({super.key, required this.title, required this.node, this.onFocusChange});

  final TmdbTitle title;
  final FocusNode node;
  final ValueChanged<bool>? onFocusChange;

  @override
  Widget build(BuildContext context) {
    final t = title;
    return PosterCard(
      node: node,
      art: placeholderArt(t.key),
      image: TmdbImage(path: t.posterPath, fallbackSeed: t.key),
      title: t.title,
      subtitle: tmdbSubtitle(t),
      onActivate: () => openTmdbTitle(context, t),
      onFocusChange: onFocusChange,
    );
  }
}

class TmdbPersonCard extends StatelessWidget {
  const TmdbPersonCard({super.key, required this.person, required this.node});

  final TmdbPerson person;
  final FocusNode node;

  @override
  Widget build(BuildContext context) => PersonCard(
    node: node,
    art: placeholderArt('p${person.id}'),
    image: person.profilePath == null
        ? null
        : TmdbImage(path: person.profilePath, kind: TmdbImageKind.profile, width: 160, fallbackSeed: 'p${person.id}'),
    name: person.name,
    role: person.role,
    onActivate: () => context.push('/tmdb/person/${person.id}'),
  );
}
