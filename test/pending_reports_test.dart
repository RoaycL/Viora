import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/history/pending_reports.dart';
import 'package:viora/data/media/media_models.dart';

/// 假服务器：记录补发的停止上报；[lastPlayed] 是服务器上这一集最后一次播放的时间
class FakeClient extends EmbyClient {
  FakeClient({this.lastPlayed, this.online = true})
    : super(
        config: const AppConfig(),
        server: const ServerConfig(id: 's', name: 's', type: ServerType.emby, username: 'u', lines: []),
        appVersion: 't',
      );

  final DateTime? lastPlayed;
  bool online;
  final sent = <(String, Duration)>[];

  @override
  Future<MediaItem> item(String id) async {
    if (!online) throw const MediaServerException('连不上');
    return MediaItem(serverId: 's', id: id, kind: MediaKind.episode, name: id, lastPlayed: lastPlayed);
  }

  @override
  Future<bool> reportStopped(MediaSourceInfo s, Duration position, String? playSessionId) async {
    if (!online) return false;
    sent.add((s.itemId, position));
    return true;
  }
}

void main() {
  final at = DateTime.utc(2026, 11, 18, 20);
  PendingPlayReport report(String item, {Duration position = const Duration(minutes: 30)}) =>
      PendingPlayReport(serverId: 's', account: 'acc', itemId: item, sourceId: 'src', position: position, at: at);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('没报上去的停止上报下次启动补发，成功后删掉', () async {
    await PendingPlayReports.add(report('ep10'));
    final client = FakeClient();
    expect(await PendingPlayReports.flush((_) => client, now: at.add(const Duration(minutes: 5))), 1);
    expect(client.sent, [('ep10', const Duration(minutes: 30))]);
    expect(await PendingPlayReports.list(), isEmpty);
  });

  test('服务器收到了的不再补发', () async {
    final r = report('ep10');
    await PendingPlayReports.add(r);
    await PendingPlayReports.done(r);
    expect(await PendingPlayReports.list(), isEmpty);
  });

  test('之后在别的设备上又看过：不补发（不用旧进度覆盖新的）', () async {
    await PendingPlayReports.add(report('ep10'));
    final client = FakeClient(lastPlayed: at.add(const Duration(hours: 1)));
    expect(await PendingPlayReports.flush((_) => client, now: at.add(const Duration(hours: 2))), 0);
    expect(client.sent, isEmpty);
    expect(await PendingPlayReports.list(), isEmpty);
  });

  test('服务器暂时连不上：留着下次再补；太旧的（3 天）丢掉', () async {
    await PendingPlayReports.add(report('ep10'));
    final client = FakeClient(online: false);
    expect(await PendingPlayReports.flush((_) => client, now: at.add(const Duration(minutes: 5))), 0);
    expect(await PendingPlayReports.list(), hasLength(1));
    client.online = true;
    expect(await PendingPlayReports.flush((_) => client, now: at.add(const Duration(days: 4))), 0);
    expect(await PendingPlayReports.list(), isEmpty);
  });

  test('换了账号 / 服务器删了：丢掉', () async {
    await PendingPlayReports.add(report('ep10'));
    expect(await PendingPlayReports.flush((_) => null, now: at), 0);
    expect(await PendingPlayReports.list(), isEmpty);
  });
}
