import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/player/subtitle_look.dart';

void main() {
  test('字幕样式随播放设置保存、读回；旧配置是默认样式', () {
    const look = SubtitleLook(color: 0xFFFFE15A, edge: SubtitleEdge.outline, outline: 1.6);
    final back = PlaybackConfig.fromJson(const PlaybackConfig().copyWith(subtitleLook: look).toJson());
    expect(back.subtitleLook, look);
    expect(back.subtitleLook.isDefault, isFalse);
    expect(PlaybackConfig.fromJson(const {}).subtitleLook.isDefault, isTrue);
    expect(
      PlaybackConfig.fromJson(const {'subtitleEdge': '???', 'subtitleOutline': 99}).subtitleLook,
      const SubtitleLook(outline: 3.0),
    );
  });

  test('传给 ExoPlayer 的参数', () {
    expect(const SubtitleLook(edge: SubtitleEdge.box).toJson(), {'color': 0xFFFFFFFF, 'edge': 'box', 'outline': 1.0});
  });
}
