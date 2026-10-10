import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/media/media_models.dart';
import '../../data/tmdb/tmdb_client.dart';
import '../../ui/rows/cards.dart';
import '../../ui/widgets/server_image.dart';

/// 打开条目：可播放的条目（电影 / 单集）进详情页，剧集进详情页，文件夹进网格。
void openMediaItem(BuildContext context, MediaItem item) {
  context.push('/item/${item.serverId}/${item.id}');
}

/// 播放条目（继续观看等）
void playMediaItem(BuildContext context, MediaItem item, {bool fromStart = false}) {
  final pos = fromStart ? 0 : item.position.inMilliseconds;
  context.push('/play/${item.serverId}/${item.id}?pos=$pos');
}

String mediaSubtitle(MediaItem item) {
  final parts = <String>[
    if (item.year != null) '${item.year}',
    if (item.rating != null && item.rating! > 0) '★ ${item.rating!.toStringAsFixed(1)}',
    if (item.kind == MediaKind.series && item.childCount != null) '${item.childCount} 季',
  ];
  return parts.join(' · ');
}

/// 海报卡（电影 / 剧集）。媒体库不是中文时，用 TMDB 的中文标题。
Widget mediaPosterCard(BuildContext context, MediaItem item, FocusNode node, {VoidCallback? onMenu, int? resources}) {
  return Consumer(
    builder: (context, ref, _) => PosterCard(
      node: node,
      art: placeholderArt(item.id),
      image: ServerImage(serverId: item.serverId, image: item.primary, fallbackSeed: item.id),
      title: localizedMeta(ref, item).title,
      subtitle: mediaSubtitle(item),
      resources: resources,
      onActivate: () => openMediaItem(context, item),
      onMenu: onMenu,
    ),
  );
}

/// 横版卡（继续观看 / 单集）
Widget mediaLandscapeCard(
  BuildContext context,
  MediaItem item,
  FocusNode node, {
  String? tag,
  IconData? tagIcon,
  VoidCallback? onActivate,
  VoidCallback? onMenu,
}) {
  final isEpisode = item.kind == MediaKind.episode;
  final remaining = item.runtime != null && item.position > Duration.zero ? item.runtime! - item.position : null;
  final caption = [
    ?item.episodeLabel,
    if (remaining != null && remaining > Duration.zero) '剩 ${formatDuration(remaining)}',
  ].join(' · ');
  return LandscapeCard(
    node: node,
    art: placeholderArt(item.id),
    image: ServerImage(
      serverId: item.serverId,
      image: item.thumb ?? item.backdrop ?? item.primary,
      maxWidth: 800,
      fallbackSeed: item.id,
    ),
    title: isEpisode ? (item.seriesName ?? item.name) : item.name,
    subtitle: isEpisode ? item.name : mediaSubtitle(item),
    tag: tag,
    tagIcon: tagIcon,
    caption: caption.isEmpty ? null : caption,
    progress: item.progress,
    onActivate: onActivate ?? () => playMediaItem(context, item),
    onMenu: onMenu,
  );
}

String formatDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60;
  if (h > 0) return '$h 小时 ${m.toString().padLeft(2, '0')} 分';
  return '${d.inMinutes} 分钟';
}

/// 播放器里的时间格式 01:02:03 / 12:34
String formatClock(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  final mm = m.toString().padLeft(2, '0'), ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
