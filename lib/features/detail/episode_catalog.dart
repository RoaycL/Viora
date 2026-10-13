import 'package:flutter/material.dart';

import '../../data/media/media_models.dart';
import '../../data/tmdb/tmdb_models.dart';
import '../../ui/rows/cards.dart';
import '../../ui/rows/focus_row.dart';
import '../../ui/widgets/server_image.dart';
import '../../ui/widgets/tmdb_image.dart';
import '../../app/theme.dart';

/// TMDB 为主，保留服务器独有的集数（例如尚未被 TMDB 收录的超前资源）。
List<TmdbEpisode> mergeEpisodeCatalog(List<TmdbEpisode> metadata, List<MediaItem> library, int season) {
  final episodes = <int, TmdbEpisode>{
    for (final episode in metadata.where((e) => e.season == season)) episode.number: episode,
  };
  for (final item in library) {
    if (item.seasonNumber != season || item.episodeNumber == null) continue;
    episodes.putIfAbsent(
      item.episodeNumber!,
      () => TmdbEpisode(
        season: season,
        number: item.episodeNumber!,
        name: item.name,
        airDate: item.premiereDate,
        runtimeMinutes: item.runtime?.inMinutes,
      ),
    );
  }
  return episodes.values.toList()..sort((a, b) => a.number.compareTo(b.number));
}

List<TmdbSeason> mergeSeasonCatalog(List<TmdbSeason> metadata, List<MediaItem> library) {
  final seasons = <int, TmdbSeason>{for (final season in metadata) season.number: season};
  for (final season in library) {
    final number = season.seasonNumber;
    if (number == null) continue;
    seasons.putIfAbsent(number, () => TmdbSeason(number: number, name: season.name));
  }
  return seasons.values.toList()..sort(
    (a, b) => a.number == 0
        ? (b.number == 0 ? 0 : 1)
        : b.number == 0
        ? -1
        : a.number.compareTo(b.number),
  );
}

/// 日期是播出信息，不限制选集或播放；实际播放始终取服务器上的资源。
class EpisodeCatalogRow extends StatelessWidget {
  const EpisodeCatalogRow({
    super.key,
    required this.tvId,
    required this.season,
    required this.episodes,
    required this.selected,
    required this.library,
    required this.libraryLoaded,
    required this.onSelect,
    this.seasonLabel,
  });

  final int tvId;
  final int season;
  final List<TmdbEpisode> episodes;
  final int selected;
  final List<MediaItem> library;
  final bool libraryLoaded;
  final ValueChanged<int> onSelect;
  final String? seasonLabel;

  @override
  Widget build(BuildContext context) {
    final initial = episodes.indexWhere((e) => e.number == selected);
    String two(int n) => n.toString().padLeft(2, '0');
    return FocusRow(
      key: ValueKey('episode-catalog-$tvId-$season'),
      rowIndex: 2,
      leading: VSpace.safeH,
      title: seasonLabel,
      initialIndex: initial < 0 ? 0 : initial,
      itemCount: episodes.length,
      itemExtent: LandscapeCard.width,
      height: LandscapeCard.height,
      itemBuilder: (context, i, node) {
        final episode = episodes[i];
        final have = library
            .where((item) => item.seasonNumber == season && item.episodeNumber == episode.number)
            .firstOrNull;
        final isSelected = episode.number == selected;
        final status = [
          if (episode.upcoming) '未播出',
          if (have != null) '已入库' else if (libraryLoaded && !episode.upcoming) '无资源',
        ].join(' · ');
        final image = have?.thumb ?? have?.primary;
        return LandscapeCard(
          key: ValueKey('episode-$season-${episode.number}'),
          node: node,
          art: placeholderArt('$tvId/$season/${episode.number}'),
          image: episode.stillPath == null && have != null && image != null
              ? ServerImage(serverId: have.serverId, image: image, width: LandscapeCard.width, fallbackSeed: have.id)
              : TmdbImage(
                  path: episode.stillPath,
                  kind: TmdbImageKind.still,
                  width: LandscapeCard.width,
                  fallbackSeed: '$tvId/$season/${episode.number}',
                ),
          title: '${episode.number}. ${episode.name}',
          subtitle: [
            if (episode.airDate case final date?)
              '${episode.upcoming ? '预计播出 ' : ''}${date.year}-${two(date.month)}-${two(date.day)}'
            else
              '播出日期待定',
            if (episode.runtimeMinutes != null && episode.runtimeMinutes! > 0) '${episode.runtimeMinutes} 分钟',
          ].join(' · '),
          tag: status.isNotEmpty
              ? status
              : isSelected
              ? '已选择'
              : null,
          tagIcon: isSelected ? Icons.check_circle_rounded : null,
          progress: have?.played == true ? 1.0 : have?.progress,
          onActivate: () => onSelect(episode.number),
        );
      },
    );
  }
}
