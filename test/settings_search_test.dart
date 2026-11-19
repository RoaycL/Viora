import 'package:flutter_test/flutter_test.dart';
import 'package:viora/features/settings/settings_page.dart';
import 'package:viora/ui/widgets/form.dart';

void main() {
  test('设置搜索：按名字、别名、分类找到设置项', () {
    expect(settingSearchLabels('托盘'), contains('关闭窗口时最小化到托盘 · 界面与窗口'));
    expect(settingSearchLabels('ua'), contains('播放 UA · 媒体服务器'));
    expect(settingSearchLabels('clash'), contains('跟随 Windows 系统代理 · 接口与网络'));
    expect(settingSearchLabels('字幕 繁体'), contains('默认字幕 · 播放'));
    expect(settingSearchLabels('  '), isEmpty);
    expect(settingSearchLabels('完全不存在的设置'), isEmpty);
  });

  test('Windows 上不列出电视专属设置', () {
    expect(settingSearchLabels('帧率'), isEmpty);
  });

  test('标签里的括号说明拆成「i」提示', () {
    expect(splitHint('资源排序（一部片有多个版本时默认选哪个）'), ('资源排序', '一部片有多个版本时默认选哪个'));
    expect(splitHint('字号'), ('字号', null));
    expect(splitHint('（开头就是括号）'), ('（开头就是括号）', null));
  });
}
