import 'package:flutter/material.dart';

import '../../data/media/media_models.dart';
import '../../data/tmdb/tmdb_models.dart';
import '../../ui/rows/cards.dart';
import '../../ui/rows/focus_row.dart';
import '../../ui/widgets/server_image.dart';
import '../../ui/widgets/tmdb_image.dart';
import '../../app/theme.dart';

/// TMDB 为主，保留服务器独有的集数（例如尚未被 TMDB 收录的超前资源）。
///
/// [trustedSeries]（`服务器/剧 ID`）：只有这些剧能添加 TMDB 没有的集。只按片名对上的同名剧
/// 可能是另一部，它的集数不能混进选集（仍可给 TMDB 列出的集提供资源）。为 null 时不限制；
/// TMDB 这一季没有数据、可信的剧也没有这一季时，退回用全部服务器的集。
List<TmdbEpisode> mergeEpisodeCatalog(
  List<TmdbEpisode> metadata,
  List<MediaItem> library,
  int season, {
  Set<String>? trustedSeries,
}) {
  final episodes = <int, TmdbEpisode>{
    for (final episode in metadata.where((e) => e.season == season)) episode.number: episode,
  };
  bool trusted(MediaItem item) => trustedSeries == null || trustedSeries.contains('${item.serverId}/${item.seriesId}');
  final inSeason = library.where((i) => i.seasonNumber == season && i.episodeNumber != null).toList();
  final restrict = episodes.isNotEmpty || inSeason.any(trusted);
  for (final item in inSeason) {
    if (restrict && !trusted(item)) continue;
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

/// 能确认是这部剧的服务器副本：当前服务器上的这部剧 + TMDB ID 一致的副本
Set<String> idConfirmedSeries(int tmdbId, List<MediaItem> copies, {String? homeServerId, String? homeSeriesId}) => {
  if (homeServerId != null && homeSeriesId != null) '$homeServerId/$homeSeriesId',
  for (final c in copies)
    if (c.tmdbId?.trim() == '$tmdbId') '${c.serverId}/${c.id}',
};

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
      // 集列表从服务器的几集换成 TMDB 全部集数时，焦点和行记忆跟着集号走，不停在同位置的另一集
      itemKeys: [for (final e in episodes) e.number],
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
