import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/player/engine.dart';
import 'package:viora/player/subtitle_pick.dart';

void main() {
  const hans = EngineTrack(id: '1', title: '简体中文', language: 'chi');
  const hant = EngineTrack(id: '2', title: '繁體中文', language: 'chi');
  const eng = EngineTrack(id: '3', language: 'eng');
  const bilingual = EngineTrack(id: '4', title: '中英双语', language: 'chi');
  const plainZh = EngineTrack(id: '5', language: 'zho');
  const externalHans = EngineTrack(id: '6', title: '简体', language: 'chi', external: true);

  test('跟随片源：不改', () {
    expect(pickSubtitle([hans, eng], SubtitlePreference.auto), (false, null));
  });

  test('不显示：关闭字幕', () {
    expect(pickSubtitle([hans, eng], SubtitlePreference.off), (true, null));
  });

  test('简体 / 繁体 / 英文各自选对', () {
    expect(pickSubtitle([eng, hant, hans], SubtitlePreference.zhHans).$2, hans);
    expect(pickSubtitle([eng, hans, hant], SubtitlePreference.zhHant).$2, hant);
    expect(pickSubtitle([bilingual, hans, eng], SubtitlePreference.en).$2, eng);
  });

  test('只标了中文的轨道按简体算；找不到对应语言时不动', () {
    expect(pickSubtitle([eng, plainZh], SubtitlePreference.zhHans).$2, plainZh);
    expect(pickSubtitle([eng, hans], SubtitlePreference.zhHant), (false, null));
    expect(pickSubtitle(const [], SubtitlePreference.en), (false, null));
  });

  test('同样匹配时内封优先于外挂', () {
    expect(pickSubtitle([externalHans, hans], SubtitlePreference.zhHans).$2, hans);
  });

  test('默认字幕设置保存 / 读取，旧配置为跟随片源', () {
    const c = PlaybackConfig(subtitlePreference: SubtitlePreference.zhHant);
    expect(PlaybackConfig.fromJson(c.toJson()).subtitlePreference, SubtitlePreference.zhHant);
    expect(PlaybackConfig.fromJson(const {}).subtitlePreference, SubtitlePreference.auto);
  });
}
