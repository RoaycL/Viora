import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora/features/update/app_version.dart';
import 'package:viora/features/update/update_source.dart';

void main() {
  late HttpServer server;
  late Object body;

  setUp(() async {
    HttpOverrides.global = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(body));
      await req.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  Uri local(Uri u) => Uri.parse('http://127.0.0.1:${server.port}${u.path}');

  Map<String, dynamic> release(String tag, {bool prerelease = false}) => {
    'tag_name': tag,
    'prerelease': prerelease,
    'draft': false,
    'body': '',
    'assets': [
      {'name': 'Viora-x-windows-setup.exe', 'browser_download_url': 'https://example.invalid/$tag.exe', 'size': 1},
    ],
  };

  GitHubReleasesSource source({required bool beta}) =>
      GitHubReleasesSource('o', 'r', userAgent: 't', rewrite: local, includePrerelease: beta);

  test('关闭「检查测试版」只取正式版；打开时取最新的（测试版标签 beta-v…）', () async {
    body = [
      release('beta-v0.15.35', prerelease: true),
      release('v0.15.34'),
      release('v0.15.33'),
      release('v0.15.32', prerelease: true), // 以前的版本都标成了预发布
    ];
    final stable = await source(beta: false).latest(UpdatePlatform.windows);
    expect(stable!.label, 'v0.15.34');
    expect(stable.prerelease, isFalse);

    final beta = await source(beta: true).latest(UpdatePlatform.windows);
    expect(beta!.version, const AppVersion(0, 15, 35));
    expect(beta.prerelease, isTrue);
    expect(beta.label, 'v0.15.35（测试版）');
  });

  test('测试版比正式版旧时，打开开关也取正式版', () async {
    body = [release('v0.15.36'), release('beta-v0.15.35', prerelease: true)];
    expect((await source(beta: true).latest(UpdatePlatform.windows))!.label, 'v0.15.36');
  });

  test('旧版本（v0.15.33 及以前）解析不了 beta- 标签：只会看到正式版', () {
    // 旧版本直接用 AppVersion.tryParse(tag)
    expect(AppVersion.tryParse('beta-v0.15.35'), isNull);
    expect(AppVersion.tryParse('v0.15.34'), isNotNull);
    expect(parseReleaseTag('beta-v0.15.35')!.$2, isTrue);
    expect(parseReleaseTag('v0.15.34')!.$2, isFalse);
    expect(parseReleaseTag('v0.15.32', prerelease: true)!.$2, isTrue);
  });

  test('新的测试版标签 beta-v<下一个正式版>-betaN：beta1 < beta2 < 正式版', () async {
    final b1 = AppVersion.tryParse('0.17.6-beta1+68')!;
    final b2 = AppVersion.tryParse('v0.17.6-beta2')!;
    final stable = AppVersion.tryParse('v0.17.6')!;
    expect(b1.isBeta && b2.isBeta, isTrue);
    expect(b2 > b1, isTrue);
    expect(stable > b2, isTrue);
    expect(b1 > AppVersion.tryParse('0.17.5+67')!, isTrue);
    expect(AppVersion.tryParse('0.17.7-beta1')! > stable, isTrue);
    expect(b2.toString(), '0.17.6-beta2');
    expect(parseReleaseTag('beta-v0.17.6-beta2')!.$1, b2);
    expect(parseReleaseTag('beta-v0.17.6-beta2')!.$2, isTrue);
    // v0.15.33 及以前直接用 AppVersion.tryParse(tag)、不看预发布：保留 beta- 前缀让它们解析不了
    expect(AppVersion.tryParse('beta-v0.17.6-beta1'), isNull);

    body = [release('beta-v0.17.6-beta2', prerelease: true), release('beta-v0.17.6-beta1', prerelease: true), release('v0.17.5')];
    final beta = await source(beta: true).latest(UpdatePlatform.windows);
    expect(beta!.version, b2);
    expect(beta.label, 'v0.17.6-beta2（测试版）');
    expect((await source(beta: false).latest(UpdatePlatform.windows))!.label, 'v0.17.5');

    body = [release('v0.17.6'), release('beta-v0.17.6-beta2', prerelease: true)];
    expect((await source(beta: true).latest(UpdatePlatform.windows))!.label, 'v0.17.6');
  });

  test('自建清单：prerelease 为 true 的只在打开开关时提示', () async {
    body = {
      'version': '0.15.35',
      'prerelease': true,
      'assets': {
        'windows': {'url': 'https://example.invalid/a.exe'},
      },
    };
    final url = Uri.parse('http://127.0.0.1:${server.port}/latest.json');
    expect(await ManifestSource(url, userAgent: 't').latest(UpdatePlatform.windows), isNull);
    final beta = await ManifestSource(url, userAgent: 't', includePrerelease: true).latest(UpdatePlatform.windows);
    expect(beta!.label, 'v0.15.35（测试版）');
  });
}
