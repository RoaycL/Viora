import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/emby/emby_client.dart';

void main() {
  const where = 'test.28.al 返回 HTTP 403';

  test('登录被拒：设备数超限、UA 被拦、密码错误分别说明', () {
    expect(loginRejectedMessage(403, {'error': 'device limit exceeded'}, where), contains('设备数已达上限'));
    expect(
      loginRejectedMessage(403, '<html><head><title>403 Forbidden</title></head></html>', where),
      contains('播放 UA'),
    );
    expect(loginRejectedMessage(403, {'error': 'access denied'}, where), contains('播放 UA'));
    expect(loginRejectedMessage(401, 'Invalid username or password entered.', where), startsWith('用户名或密码错误'));
    expect(loginRejectedMessage(401, null, where), startsWith('用户名或密码错误'));
    expect(loginRejectedMessage(403, {'error': 'account disabled'}, where), '服务器拒绝登录（$where：account disabled）');
  });
}
