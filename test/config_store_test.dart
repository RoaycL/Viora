import 'dart:async';
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

class _DelayedVault extends MemoryVault {
  final started = Completer<void>();
  final release = Completer<void>();
  int writes = 0;

  @override
  Future<void> write(String key, String? value) async {
    writes++;
    if (writes == 1) {
      started.complete();
      await release.future;
    }
    await super.write(key, value);
  }
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

  test('较慢的旧保存不能覆盖新的配置和密码', () async {
    SharedPreferences.setMockInitialValues({'viora.config.v1': oldJson});
    final vault = _DelayedVault();
    ConfigStore.vault = vault;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(configProvider.notifier);
    await store.load();
    final first = store.updateServer('s1', (s) => s.copyWith(password: 'first'));
    await vault.started.future;
    final second = store.updateServer('s1', (s) => s.copyWith(name: 'new name', password: 'second'));
    await Future<void>.delayed(Duration.zero);
    expect(vault.writes, 1, reason: '第二次保存必须等前一次密钥库写入结束');
    vault.release.complete();
    await Future.wait([first, second]);
    final reloaded = ProviderContainer();
    addTearDown(reloaded.dispose);
    await reloaded.read(configProvider.notifier).load();
    expect(reloaded.read(configProvider).server('s1')!.name, 'new name');
    expect(reloaded.read(configProvider).server('s1')!.password, 'second');
  });

  test('后台连接不能复活删除的服务器，也不能覆盖用户的新修改', () async {
    SharedPreferences.setMockInitialValues({'viora.config.v1': oldJson});
    ConfigStore.vault = MemoryVault();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(configProvider.notifier);
    await store.load();
    final initial = container.read(configProvider).server('s1')!;
    await store.updateServer('s1', (s) => s.copyWith(password: 'edited'));
    expect(await store.replaceServerIfUnchanged(initial, initial.copyWith(token: 'stale')), isFalse);
    expect(container.read(configProvider).server('s1')!.password, 'edited');
    final edited = container.read(configProvider).server('s1')!;
    expect(await store.replaceServerIfUnchanged(edited, edited.copyWith(token: 'fresh')), isTrue);
    final connected = container.read(configProvider).server('s1')!;
    await store.removeServer('s1');
    expect(await store.replaceServerIfUnchanged(connected, connected), isFalse);
    expect(container.read(configProvider).allServers, isEmpty);
  });

  test('后台连接期间测速、改了其他设置：连接结果照常保存，用户改的设置保留', () async {
    SharedPreferences.setMockInitialValues({'viora.config.v1': oldJson});
    ConfigStore.vault = MemoryVault();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(configProvider.notifier);
    await store.load();
    final initial = container.read(configProvider).server('s1')!;
    // 连接进行中：别处更新了这台服务器（测速、用户关掉聚合），对象已经不是同一个
    await store.updateServer('s1', (s) => s.copyWith(aggregate: false, movieCount: 12));
    expect(await store.replaceServerIfUnchanged(initial, initial.copyWith(token: 'fresh', userId: 'u1')), isTrue);
    final saved = container.read(configProvider).server('s1')!;
    expect(saved.token, 'fresh');
    expect(saved.userId, 'u1');
    expect(saved.aggregate, isFalse);
    expect(saved.movieCount, 12);
  });

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
