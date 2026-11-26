import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// 进度条缩略图（拖动 / 快进快退时显示目标位置的画面）。
///
/// 两种来源，都由服务器预先生成（服务器没开「缩略图 / 预览图提取」就没有）：
/// - Jellyfin 10.9+：trickplay 拼图，每张 JPG 是 列 × 行 个缩略图，按需取用到的那一张
/// - Emby：BIF 文件（Roku 格式），一次下载，里面是一串 JPG
abstract class Trickplay {
  /// 缩略图宽 / 高
  double get aspect;

  /// [t] 附近的缩略图；还没下载好或出错时返回 null。
  /// 返回的帧持有图片的一份引用，用完要 [TrickplayFrame.dispose]
  Future<TrickplayFrame?> frameAt(Duration t);

  /// 释放缓存的图片（退出播放、换版本时）。已经交出去的帧各自释放
  void dispose();
}

class TrickplayFrame {
  const TrickplayFrame(this.image, this.src);

  final ui.Image image;

  void dispose() => image.dispose();

  /// 缩略图在 [image] 里的位置（像素）
  final ui.Rect src;
}

// ───────────────────────── Jellyfin ─────────────────────────

/// Jellyfin 的 TrickplayInfo：[columns] × [rows] 个缩略图拼成一张图，每 [interval] 一张，共 [count] 张
class TrickplayTiles {
  const TrickplayTiles({
    required this.width,
    required this.height,
    required this.columns,
    required this.rows,
    required this.count,
    required this.interval,
  });

  final int width;
  final int height;
  final int columns;
  final int rows;
  final int count;
  final Duration interval;

  /// 服务器返回的 Trickplay 字段：{ 媒体源 ID: { "320": TrickplayInfo, ... } }。
  /// 选 [mediaSourceId] 的（没有就第一个），宽度取最接近 [preferWidth] 的
  static TrickplayTiles? parse(Object? json, String mediaSourceId, {int preferWidth = 320}) {
    if (json is! Map || json.isEmpty) return null;
    final bySource = json[mediaSourceId] ?? json.values.first;
    if (bySource is! Map || bySource.isEmpty) return null;
    TrickplayTiles? best;
    for (final v in bySource.values) {
      if (v is! Map) continue;
      int n(String k) => (v[k] as num?)?.toInt() ?? 0;
      final t = TrickplayTiles(
        width: n('Width'),
        height: n('Height'),
        columns: n('TileWidth'),
        rows: n('TileHeight'),
        count: n('ThumbnailCount'),
        interval: Duration(milliseconds: n('Interval')),
      );
      if (t.width <= 0 || t.height <= 0 || t.columns <= 0 || t.rows <= 0 || t.count <= 0) continue;
      if (t.interval <= Duration.zero) continue;
      if (best == null || (t.width - preferWidth).abs() < (best.width - preferWidth).abs()) best = t;
    }
    return best;
  }

  /// [t] 对应第几张拼图、在拼图里的位置
  (int tile, ui.Rect src) cellAt(Duration t) {
    final index = (t.inMilliseconds ~/ interval.inMilliseconds).clamp(0, count - 1);
    final perTile = columns * rows;
    final within = index % perTile;
    final col = within % columns, row = within ~/ columns;
    return (
      index ~/ perTile,
      ui.Rect.fromLTWH((col * width).toDouble(), (row * height).toDouble(), width.toDouble(), height.toDouble()),
    );
  }
}

class JellyfinTrickplay implements Trickplay {
  JellyfinTrickplay(this.tiles, this._fetchTile);

  final TrickplayTiles tiles;

  /// 下载第 n 张拼图（JPG 字节）
  final Future<Uint8List> Function(int tile) _fetchTile;

  /// 已解码的拼图：一张通常有 100 个缩略图（10 × 10），留最近用过的几张就够来回拖
  final _cache = <int, Future<ui.Image?>>{};
  static const _keep = 6;
  bool _disposed = false;

  @override
  double get aspect => tiles.width / tiles.height;

  @override
  Future<TrickplayFrame?> frameAt(Duration t) async {
    if (_disposed) return null;
    final (tile, src) = tiles.cellAt(t);
    final image = await _tile(tile);
    if (image == null || _disposed || _gone[image] == true) return null;
    // 最后一张拼图可能不满（高度更小）：超出范围的就不显示
    if (src.right > image.width || src.bottom > image.height) return null;
    return TrickplayFrame(image.clone(), src);
  }

  @override
  void dispose() {
    _disposed = true;
    for (final f in _cache.values) {
      _release(f);
    }
    _cache.clear();
  }

  Future<ui.Image?> _tile(int tile) {
    final hit = _cache.remove(tile);
    if (hit != null) return _cache[tile] = hit; // 移到最后（最近用过）
    final f = _fetchTile(tile).then<ui.Image?>(decodeImage).catchError((Object e) {
      debugPrint('trickplay: tile $tile $e');
      _cache.remove(tile); // 下次再试
      return null;
    });
    _cache[tile] = f;
    while (_cache.length > _keep) {
      _release(_cache.remove(_cache.keys.first));
    }
    return f;
  }
}

// ───────────────────────── Emby（BIF） ─────────────────────────

/// BIF 文件的索引：每张缩略图的时间和在文件里的位置
class BifIndex {
  const BifIndex(this.times, this.offsets);

  /// 每张的时间（毫秒），从小到大
  final List<int> times;

  /// 每张 JPG 的起点；比 [times] 多一项（最后一项是数据结尾）
  final List<int> offsets;

  int get length => times.length;

  static const _magic = [0x89, 0x42, 0x49, 0x46, 0x0d, 0x0a, 0x1a, 0x0a];

  /// 格式：8 字节标识，版本、张数、时间单位（毫秒，0 表示 1000），64 字节起是索引：
  /// 每项（时间, 偏移）各 4 字节小端，最后一项时间为 0xffffffff、偏移为数据结尾。不是 BIF 时返回 null
  static BifIndex? parse(Uint8List bytes) {
    if (bytes.length < 64) return null;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return null;
    }
    final d = ByteData.sublistView(bytes);
    final count = d.getUint32(12, Endian.little);
    var unit = d.getUint32(16, Endian.little);
    if (unit == 0) unit = 1000;
    if (64 + (count + 1) * 8 > bytes.length) return null;
    final times = <int>[], offsets = <int>[];
    for (var i = 0; i <= count; i++) {
      final ts = d.getUint32(64 + i * 8, Endian.little);
      final off = d.getUint32(68 + i * 8, Endian.little);
      if (off > bytes.length || (offsets.isNotEmpty && off < offsets.last)) return null;
      offsets.add(off);
      if (i < count) {
        if (ts == 0xffffffff) return null;
        times.add(ts * unit);
      }
    }
    return count == 0 ? null : BifIndex(times, offsets);
  }

  /// [t] 时刻显示哪一张：时间不晚于 [t] 的最后一张
  int indexAt(Duration t) {
    final ms = t.inMilliseconds;
    var lo = 0, hi = times.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (times[mid] <= ms) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }
}

class BifTrickplay implements Trickplay {
  BifTrickplay(this._bytes, this.index, this.aspect);

  final Uint8List _bytes;
  final BifIndex index;

  @override
  final double aspect;

  final _cache = <int, Future<ui.Image?>>{};
  static const _keep = 24;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    for (final f in _cache.values) {
      _release(f);
    }
    _cache.clear();
  }

  /// 解析 BIF；宽高比从第一张图里读
  static Future<BifTrickplay?> load(Uint8List bytes) async {
    final index = BifIndex.parse(bytes);
    if (index == null) return null;
    final first = await decodeImage(Uint8List.sublistView(bytes, index.offsets[0], index.offsets[1]));
    final aspect = first.height > 0 ? first.width / first.height : 16 / 9;
    final t = BifTrickplay(bytes, index, aspect);
    t._cache[0] = Future.value(first);
    return t;
  }

  @override
  Future<TrickplayFrame?> frameAt(Duration t) async {
    if (_disposed) return null;
    final i = index.indexAt(t);
    final hit = _cache.remove(i);
    final f =
        hit ??
        decodeImage(Uint8List.sublistView(_bytes, index.offsets[i], index.offsets[i + 1])).then<ui.Image?>(
          (v) => v,
          onError: (Object e) {
            debugPrint('trickplay: bif $i $e');
            return null;
          },
        );
    _cache[i] = f;
    while (_cache.length > _keep) {
      _release(_cache.remove(_cache.keys.first));
    }
    final image = await f;
    if (image == null || _disposed || _gone[image] == true) return null;
    return TrickplayFrame(image.clone(), ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()));
  }
}

/// 缓存里淘汰的图片：解码完（或已经解码好）就释放显存（交出去的帧是各自的 clone，不受影响）
void _release(Future<ui.Image?>? f) => f?.then((image) {
  if (image == null) return;
  _gone[image] = true;
  image.dispose();
}, onError: (_) {}).ignore();

/// 已经释放的缓存图片（还在等它的 frameAt 不能再用）
final _gone = Expando<bool>();

Future<ui.Image> decodeImage(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}
