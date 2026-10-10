import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/config/app_config.dart';
import 'package:viora/data/emby/emby_client.dart';
import 'package:viora/data/segments/server_provider.dart';
import 'package:viora/domain/models/segment.dart';
import 'package:viora/domain/usecases/segment_resolver.dart';

class _FakeClient extends EmbyClient {
  _FakeClient({this.segments = const [], this.chapterList = const []})
    : super(
        config: const AppConfig(deviceId: 't'),
        server: const ServerConfig(
          id: 's',
          type: ServerType.jellyfin,
          name: 's',
          username: 'u',
          lines: [ServerLine(id: 'l', name: 'l', url: 'https://example.com')],
        ),
        appVersion: 't',
      );

  final List<ServerMediaSegment> segments;
  final List<ServerChapter> chapterList;
  int chapterCalls = 0;

  @override
  Future<List<ServerMediaSegment>> mediaSegments(String itemId) async => segments;

  @override
  Future<List<ServerChapter>> chapters(String itemId) async {
    chapterCalls++;
    return chapterList;
  }
}

const _duration = Duration(minutes: 45);
const _query = SegmentQuery(titleKey: 't', kind: SegmentMediaKind.episode, duration: _duration, season: 1, episode: 2);

void main() {
  test('Jellyfin 媒体片段：Intro / Outro / Recap 映射，结尾超出一点时收回', () async {
    final source = ServerSegmentSource(
      _FakeClient(
        segments: const [
          ServerMediaSegment(type: 'Intro', start: Duration(seconds: 60), end: Duration(seconds: 150)),
          ServerMediaSegment(type: 'Outro', start: Duration(minutes: 43), end: Duration(minutes: 45, seconds: 2)),
          ServerMediaSegment(type: 'Recap', start: Duration.zero, end: Duration(seconds: 40)),
          ServerMediaSegment(type: 'Commercial', start: Duration(minutes: 20), end: Duration(minutes: 21)),
        ],
      ),
      'i',
    );
    final c = await ServerSegmentProvider(source).fetch(_query);
    expect(c.map((e) => e.type), [SegmentType.intro, SegmentType.credits, SegmentType.recap]);
    expect(c[1].end, _duration);
    final resolved = await SegmentResolver(providers: [ServerSegmentProvider(source)]).resolve(_query);
    expect(resolved.segments.map((s) => s.type), [SegmentType.recap, SegmentType.intro, SegmentType.credits]);
  });

  test('Emby 章节标记：IntroStart / IntroEnd / CreditsStart', () async {
    final source = ServerSegmentSource(
      _FakeClient(
        chapterList: const [
          ServerChapter(name: 'Chapter 1', start: Duration.zero, marker: 'Chapter'),
          ServerChapter(name: 'Intro', start: Duration(seconds: 90), marker: 'IntroStart'),
          ServerChapter(name: 'Intro End', start: Duration(seconds: 180), marker: 'IntroEnd'),
          ServerChapter(name: 'Credits', start: Duration(minutes: 42), marker: 'CreditsStart'),
        ],
      ),
      'i',
    );
    final c = await ServerSegmentProvider(source).fetch(_query);
    expect(c.first.type, SegmentType.intro);
    expect(c.first.start, const Duration(seconds: 90));
    expect(c.first.end, const Duration(seconds: 180));
    expect(c.last.type, SegmentType.credits);
    expect(c.last.end, isNull);
  });

  test('章节名识别：OP / ED，章节只取一次；服务器标记优先', () async {
    final client = _FakeClient(
      chapterList: const [
        ServerChapter(name: 'Avant', start: Duration.zero),
        ServerChapter(name: 'OP', start: Duration(seconds: 70)),
        ServerChapter(name: 'Part A', start: Duration(seconds: 160)),
        ServerChapter(name: 'ED', start: Duration(minutes: 43)),
      ],
    );
    final source = ServerSegmentSource(client, 'i');
    final resolver = SegmentResolver(providers: [ServerSegmentProvider(source), ChapterNameSegmentProvider(source)]);
    final r = await resolver.resolve(_query);
    expect(client.chapterCalls, 1);
    final intro = r.segments.firstWhere((s) => s.type == SegmentType.intro);
    expect(intro.start, const Duration(seconds: 70));
    expect(intro.end, const Duration(seconds: 160));
    expect(intro.provider, 'chapters');
    final credits = r.segments.firstWhere((s) => s.type == SegmentType.credits);
    expect(credits.end, _duration);
  });
}
