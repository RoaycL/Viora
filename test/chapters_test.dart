import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/player/chapters.dart';

ServerChapter c(int s, [String name = '', String? marker]) => ServerChapter(
  name: name,
  start: Duration(seconds: s),
  marker: marker,
);

void main() {
  test('章节去掉片头片尾标记、排序去重', () {
    final list = chapterList([
      c(600, '第二章'),
      c(0, '开场'),
      c(90, '', 'IntroStart'),
      c(180, '', 'IntroEnd'),
      c(600, '重复'),
      c(2400, '', 'CreditsStart'),
    ]);
    expect(list.map((x) => x.name), ['开场', '第二章']);
  });

  test('少于 2 个章节不显示', () {
    expect(chapterList([c(0, '唯一')]), isEmpty);
    expect(chapterList([c(0, '', 'IntroStart'), c(60, '正片')]), isEmpty);
  });

  test('当前章节', () {
    final list = [c(10), c(100), c(200)];
    expect(currentChapterIndex(list, const Duration(seconds: 5)), -1);
    expect(currentChapterIndex(list, const Duration(seconds: 100)), 1);
    expect(currentChapterIndex(list, const Duration(hours: 1)), 2);
  });

  test('HDR 字幕亮度和解码方式按设备保存', () {
    final p = const PlaybackConfig().copyWith(hdrSubtitleBrightness: 0.7, mpvHardwareDecoding: false);
    final back = PlaybackConfig.fromJson(p.toJson());
    expect(back.hdrSubtitleBrightness, 0.7);
    expect(back.mpvHardwareDecoding, isFalse);
    expect(PlaybackConfig.fromJson(const {}).mpvHardwareDecoding, isTrue);
    expect(PlaybackConfig.fromJson(const {}).hdrSubtitleBrightness, 1.0);
  });
}
