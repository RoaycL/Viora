import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';

class _BrokenVault implements SecretVault {
  @override
  Future<String?> read(String key) async => throw Exception('keystore unavailable');

  @override
  Future<void> write(String key, String? value) async => throw Exception('keystore unavailable');
}

void main() {
  const server = ServerConfig(
    id: 's1',
    type: ServerType.emby,
    name: '家里',
    lines: [ServerLine(id: 'l', name: '主线路', url: 'https://emby.home.com')],
    username: 'me',
    password: 'secret',
    userId: 'u',
    token: 'tok',
  );
  final oldJson = jsonEncode(const AppConfig(servers: [server], deviceId: 'dev').toJson());

  Future<Map<String, dynamic>> saved() async =>
      jsonDecode((await SharedPreferences.getInstance()).getString('viora.config.v1')!) as Map<String, dynamic>;

  test('旧版本的明文密码：读取正常，保存后移进密钥库，配置里不再有密码和令牌', () async {
    SharedPreferences.setMockInitialValues({'viora.config.v1': oldJson});
    final vault = MemoryVault();
    ConfigStore.vault = vault;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(configProvider.notifier).load();
    expect(container.read(configProvider).server('s1')!.password, 'secret');

    await container.read(configProvider.notifier).update((c) => c);
    final json = await saved();
    final s = (json['servers'] as List).single as Map<String, dynamic>;
    expect(s['password'], '');
    expect(s['token'], isNull);
    expect(vault.values['viora.server.s1.password'], 'secret');
    expect(vault.values['viora.server.s1.token'], 'tok');

    // 重新启动：从密钥库补回
    final again = ProviderContainer();
    addTearDown(again.dispose);
    await again.read(configProvider.notifier).load();
    expect(again.read(configProvider).server('s1')!.password, 'secret');
    expect(again.read(configProvider).server('s1')!.loggedIn, isTrue);

    // 删除服务器：密钥库里的密码一起删掉
    await again.read(configProvider.notifier).removeServer('s1');
    expect(vault.values, isEmpty);
  });

  test('密钥库不可用（部分电视盒子）：退回保存在配置里，不丢登录', () async {
    SharedPreferences.setMockInitialValues({'viora.config.v1': oldJson});
    ConfigStore.vault = _BrokenVault();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(configProvider.notifier).load();
    await container.read(configProvider.notifier).update((c) => c);
    final s = ((await saved())['servers'] as List).single as Map<String, dynamic>;
    expect(s['password'], 'secret');
    expect(s['token'], 'tok');
  });
}
