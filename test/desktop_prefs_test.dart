import 'package:flutter_test/flutter_test.dart';
import 'package:viora/app/desktop_prefs.dart';

void main() {
  const regOn = '''
HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings
    ProxyEnable    REG_DWORD    0x1
    ProxyServer    REG_SZ    127.0.0.1:7890
    ProxyOverride    REG_SZ    localhost;*.lan;<local>
''';

  test('读系统代理：开启时返回地址和不走代理的列表；关闭时为空', () {
    final r = SystemProxy.parseRegQuery(regOn)!;
    expect(r.$1, '127.0.0.1:7890');
    expect(r.$2, ['localhost', '*.lan', '<local>']);
    expect(SystemProxy.parseRegQuery(regOn.replaceFirst('0x1', '0x0')), isNull);
    // 按协议分别设置的写法
    final split = regOn.replaceFirst('127.0.0.1:7890', 'http=127.0.0.1:7890;https=127.0.0.1:7891');
    expect(SystemProxy.parseRegQuery(split)!.$1, '127.0.0.1:7891');
  });

  test('局域网 / 本机 / 系统设置里不走代理的地址直连', () {
    const bypass = ['*.lan', '<local>'];
    for (final h in ['localhost', '127.0.0.1', '192.168.1.10', '10.0.0.2', '172.20.1.1', 'nas.lan', 'nas']) {
      expect(SystemProxy.direct(h, bypass), isTrue, reason: h);
    }
    for (final h in ['api.themoviedb.org', 'emby.example.com', '172.40.1.1', '8.8.8.8']) {
      expect(SystemProxy.direct(h, bypass), isFalse, reason: h);
    }
  });
}
