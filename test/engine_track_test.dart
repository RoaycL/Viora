import 'package:flutter_test/flutter_test.dart';
import 'package:viora/player/engine.dart';

void main() {
  test('第二字幕只列文字字幕：PGS / VobSub / DVB 是图片字幕', () {
    for (final c in ['subrip', 'ass', 'webvtt', 'mov_text', null]) {
      expect(EngineTrack(id: '1', codec: c).isTextSubtitle, isTrue, reason: '$c');
    }
    for (final c in ['hdmv_pgs_subtitle', 'PGS', 'dvd_subtitle', 'dvb_subtitle']) {
      expect(EngineTrack(id: '1', codec: c).isTextSubtitle, isFalse, reason: c);
    }
  });
}
