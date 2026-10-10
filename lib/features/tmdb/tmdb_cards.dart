import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/aggregate/tmdb_link.dart';
import '../../data/media/media_models.dart';
import '../../data/tmdb/tmdb_client.dart';
import '../../ui/rows/cards.dart';
import '../../ui/widgets/server_image.dart';
import '../../ui/widgets/tmdb_image.dart';

/// 打开 TMDB 条目：媒体库里有就直接进媒体库详情（可播放），否则进 TMDB 详情。
void openTmdbTitle(BuildContext context, WidgetRef ref, TmdbTitle t) {
  final copies = ref.read(libraryCopiesProvider(linkKeyOf(t)));
  if (copies.isNotEmpty) {
    context.push('/item/${copies.first.serverId}/${copies.first.id}');
  } else {
    context.push('/tmdb/${t.type}/${t.id}');
  }
}

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

/// TMDB 海报卡：角标显示媒体库里的资源数（没有时半透明并显示"无资源"）
class TmdbPosterCard extends ConsumerWidget {
  const TmdbPosterCard({super.key, required this.title, required this.node, this.onFocusChange});

  final TmdbTitle title;
  final FocusNode node;
  final ValueChanged<bool>? onFocusChange;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = title;
    final copies = ref.watch(libraryCopiesProvider(linkKeyOf(t)));
    return PosterCard(
      node: node,
      art: placeholderArt(t.key),
      image: TmdbImage(path: t.posterPath, size: 'w342', fallbackSeed: t.key),
      title: t.title,
      subtitle: tmdbSubtitle(t),
      resources: copies.length,
      onActivate: () => openTmdbTitle(context, ref, t),
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
        : TmdbImage(path: person.profilePath, size: 'w185', fallbackSeed: 'p${person.id}'),
    name: person.name,
    role: person.role,
    onActivate: () => context.push('/tmdb/person/${person.id}'),
  );
}
