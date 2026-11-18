import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/desktop_tray.dart';

void main() {
  test('关到托盘：已经是隐藏状态也通知一次（播放器暂停），不会先变回「已恢复」', () {
    final flag = TrayHiddenFlag();
    addTearDown(flag.dispose);
    final seen = <bool>[];
    flag.addListener(() => seen.add(flag.value));
    flag.hide();
    flag.hide();
    expect(seen, [true, true]);
    flag.value = false;
    expect(seen, [true, true, false]);
  });
}
