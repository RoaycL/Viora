import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/app/platform_profile.dart';
import 'package:viora/app/theme.dart';
import 'package:viora/core/voice/voice_input.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/config/config_store.dart';
import 'package:viora/data/index/index_sync.dart';
import 'package:viora/data/index/media_index.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/features/search/search_page.dart';

const server = ServerConfig(
  id: 's',
  name: 's',
  type: ServerType.emby,
  username: 'u',
  userId: 'u',
  token: 't',
  lines: [],
);

class OneServer extends ConfigStore {
  @override
  AppConfig build() => const AppConfig(servers: [server]);
}

void main() {
  testWidgets('电视搜索页：系统有语音识别时多一个「语音」键，说完直接搜索', (tester) async {
    PlatformProfile.debugOverride = PlatformProfile.tv;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      PlatformProfile.debugOverride = PlatformProfile.desktop;
      debugDefaultTargetPlatformOverride = null;
      VoiceInput.debugReset();
    });
    VoiceInput.debugReset();
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('viora/voice'), (call) async {
      calls.add(call.method);
      return call.method == 'available' ? true : '时光代理人。';
    });
    final index = (await tester.runAsync(() => MediaIndex.open(path: ':memory:')))!;
    index.bindAccounts({'s': 'acc'});
    index.upsert('s', [MediaItem(serverId: 's', id: 'm0', kind: MediaKind.series, name: '时光代理人')]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [configProvider.overrideWith(OneServer.new), mediaIndexProvider.overrideWith((ref) async => index)],
        child: MaterialApp(
          theme: buildTheme(),
          home: const Scaffold(body: SearchPage()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('语音'), findsOneWidget);
    await tester.tap(find.text('语音'));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(calls, ['available', 'recognize']);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '时光代理人');
    expect(find.text('共 1 部作品'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
