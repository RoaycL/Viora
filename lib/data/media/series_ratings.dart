import '../config/app_config.dart';
import 'media_models.dart';

/// 剧集的分级（儿童模式判断单集用）。Emby / Jellyfin 的分级多半填在剧集上，单集自己常常没有：
/// 单集没有分级时按所属剧集的分级判断，不然本机观看记录、Plex 等地方会露出受限剧集的单集
abstract final class SeriesRatings {
  static final _known = <String, String?>{};
  static const _limit = 4000;

  /// 查聚合索引（索引里有每部剧的分级）；没有索引时为 null
  static String? Function(String serverId, String seriesId)? lookupIndex;

  static String _key(String serverId, String seriesId) => '$serverId/$seriesId';

  /// 记下列表里剧集的分级
  static void remember(Iterable<MediaItem> items) {
    for (final it in items) {
      if (it.kind != MediaKind.series) continue;
      final key = _key(it.serverId, it.id);
      _known.remove(key);
      _known[key] = it.officialRating;
    }
    while (_known.length > _limit) {
      _known.remove(_known.keys.first);
    }
  }

  static String? of(String serverId, String seriesId) {
    final key = _key(serverId, seriesId);
    if (_known.containsKey(key)) return _known[key];
    try {
      return lookupIndex?.call(serverId, seriesId);
    } catch (_) {
      return null;
    }
  }

  /// 单集用于判断的分级：自己的，没有就用所属剧集的
  static String? effective(MediaItem it) {
    if (it.officialRating != null || it.kind != MediaKind.episode || it.seriesId == null) return it.officialRating;
    return of(it.serverId, it.seriesId!);
  }

  static void clear() => _known.clear();
}

/// 儿童模式下能不能显示。单集和所属剧集都没有分级时放行：Emby / Jellyfin 服务器端已按剧集分级过滤过，
/// 而很多单集本身不填分级，按「拦截无分级」处理会把所有剧集都挡掉
bool parentalAllowsItem(ParentalConfig p, MediaItem it) {
  final rating = SeriesRatings.effective(it);
  if (it.kind == MediaKind.episode && rating == null) return true;
  return p.allows(rating);
}
