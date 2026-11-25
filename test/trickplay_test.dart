import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/player/trickplay.dart';

Uint8List bif(List<int> times, List<List<int>> images, {int unit = 1000}) {
  final header = ByteData(64)
    ..setUint32(8, 0, Endian.little)
    ..setUint32(12, times.length, Endian.little)
    ..setUint32(16, unit, Endian.little);
  final magic = [0x89, 0x42, 0x49, 0x46, 0x0d, 0x0a, 0x1a, 0x0a];
  for (var i = 0; i < 8; i++) {
    header.setUint8(i, magic[i]);
  }
  final index = ByteData((times.length + 1) * 8);
  var offset = 64 + index.lengthInBytes;
  for (var i = 0; i < times.length; i++) {
    index
      ..setUint32(i * 8, times[i], Endian.little)
      ..setUint32(i * 8 + 4, offset, Endian.little);
    offset += images[i].length;
  }
  index
    ..setUint32(times.length * 8, 0xffffffff, Endian.little)
    ..setUint32(times.length * 8 + 4, offset, Endian.little);
  return Uint8List.fromList([
    ...header.buffer.asUint8List(),
    ...index.buffer.asUint8List(),
    for (final img in images) ...img,
  ]);
}

void main() {
  group('Jellyfin trickplay', () {
    final json = {
      'src1': {
        '320': {
          'Width': 320,
          'Height': 180,
          'TileWidth': 10,
          'TileHeight': 10,
          'ThumbnailCount': 250,
          'Interval': 10000,
        },
        '640': {'Width': 640, 'Height': 360, 'TileWidth': 5, 'TileHeight': 5, 'ThumbnailCount': 250, 'Interval': 10000},
      },
    };

    test('选最接近 320 的宽度；媒体源不对时用第一个', () {
      expect(TrickplayTiles.parse(json, 'src1')!.width, 320);
      expect(TrickplayTiles.parse(json, 'other')!.width, 320);
      expect(TrickplayTiles.parse(json, 'src1', preferWidth: 600)!.width, 640);
      expect(TrickplayTiles.parse(null, 'src1'), isNull);
      expect(TrickplayTiles.parse({'src1': {}}, 'src1'), isNull);
    });

    test('时间换算成拼图和格子位置', () {
      final t = TrickplayTiles.parse(json, 'src1')!;
      var (tile, src) = t.cellAt(Duration.zero);
      expect((tile, src.left, src.top), (0, 0.0, 0.0));
      // 第 23 张：第 0 张拼图，第 2 行第 3 列
      (tile, src) = t.cellAt(const Duration(seconds: 235));
      expect((tile, src.left, src.top, src.width, src.height), (0, 960.0, 360.0, 320.0, 180.0));
      // 第 105 张：第 1 张拼图，第 0 行第 5 列
      (tile, src) = t.cellAt(const Duration(seconds: 1050));
      expect((tile, src.left, src.top), (1, 1600.0, 0.0));
      // 超出片长：停在最后一张（第 249 张）
      (tile, src) = t.cellAt(const Duration(hours: 5));
      expect((tile, src.left, src.top), (2, 2880.0, 720.0));
    });
  });

  group('BIF', () {
    test('解析索引并按时间找图', () {
      final bytes = bif(
        [0, 10, 20],
        [
          [1, 2],
          [3, 4, 5],
          [6],
        ],
      );
      final index = BifIndex.parse(bytes)!;
      expect(index.length, 3);
      expect(index.times, [0, 10000, 20000]);
      expect(bytes.sublist(index.offsets[1], index.offsets[2]), [3, 4, 5]);
      expect(index.indexAt(Duration.zero), 0);
      expect(index.indexAt(const Duration(seconds: 9)), 0);
      expect(index.indexAt(const Duration(seconds: 10)), 1);
      expect(index.indexAt(const Duration(seconds: 15)), 1);
      expect(index.indexAt(const Duration(minutes: 5)), 2);
    });

    test('时间单位为 0 时按 1000 毫秒', () {
      expect(
        BifIndex.parse(
          bif(
            [0, 5],
            [
              [1],
              [2],
            ],
            unit: 0,
          ),
        )!.times,
        [0, 5000],
      );
    });

    test('不是 BIF / 文件不完整', () {
      expect(BifIndex.parse(Uint8List(10)), isNull);
      expect(BifIndex.parse(Uint8List(100)), isNull);
      final ok = bif(
        [0, 10],
        [
          [1],
          [2],
        ],
      );
      expect(BifIndex.parse(Uint8List.sublistView(ok, 0, 70)), isNull);
    });
  });
}
