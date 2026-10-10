import '../../domain/models/segment.dart';
import '../emby/emby_client.dart';
import 'segment_provider.dart';

/// 一次播放里共用的服务器数据（章节只取一次，两个 Provider 共用）
class ServerSegmentSource {
  ServerSegmentSource(this.client, this.itemId);

  final EmbyClient client;
  final String itemId;
  Future<List<ServerChapter>>? _chapters;

  Future<List<ServerChapter>> chapters() => _chapters ??= client.chapters(itemId);
}

/// 结束时间超出文件长度一点点（服务器取整）时收回到结尾
Duration? _clampEnd(Duration? end, Duration duration) {
  if (end == null) return null;
  if (end > duration && end - duration < const Duration(seconds: 5)) return duration;
  return end;
}

/// 媒体服务器自带的片头片尾标记（docs/05 §3.1 `server`，优先级最高）：
/// - Jellyfin 10.10+：`/MediaSegments/{id}`（Intro Skipper 等插件也写到这里）
/// - Emby 4.8+：章节上的 MarkerType（IntroStart / IntroEnd / CreditsStart）
class ServerSegmentProvider implements SegmentProvider {
  ServerSegmentProvider(this.source);

  final ServerSegmentSource source;

  @override
  String get id => 'server';

  @override
  Future<List<SegmentCandidate>> fetch(SegmentQuery query) async {
    final out = <SegmentCandidate>[];
    for (final s in await source.client.mediaSegments(source.itemId)) {
      final type = switch (s.type.toLowerCase()) {
        'intro' => SegmentType.intro,
        'outro' => SegmentType.credits,
        'recap' => SegmentType.recap,
        'preview' => SegmentType.preview,
        _ => null,
      };
      if (type == null) continue;
      out.add(SegmentCandidate(type: type, start: s.start, end: _clampEnd(s.end, query.duration), provider: id));
    }
    if (out.isNotEmpty) return out;

    final chapters = await source.chapters();
    Duration? at(String marker) =>
        chapters.where((c) => c.marker?.toLowerCase() == marker.toLowerCase()).firstOrNull?.start;
    final introStart = at('IntroStart');
    final introEnd = at('IntroEnd');
    final creditsStart = at('CreditsStart');
    if (introStart != null && introEnd != null) {
      out.add(SegmentCandidate(type: SegmentType.intro, start: introStart, end: introEnd, provider: id));
    }
    if (creditsStart != null) {
      out.add(SegmentCandidate(type: SegmentType.credits, start: creditsStart, end: null, provider: id));
    }
    return out;
  }
}

/// 兜底：按章节名识别（docs/05 §3.1 `chapters`，置信度 0.6，优先级最低）。
/// 片头 = 名为 OP / Opening / Intro / 片头 的章节到下一章节开始；片尾、前情提要、预告同理。
class ChapterNameSegmentProvider implements SegmentProvider {
  ChapterNameSegmentProvider(this.source);

  final ServerSegmentSource source;

  static final _patterns = <SegmentType, RegExp>{
    SegmentType.intro: RegExp(
      r'^\s*(op|opening|intro|introduction|片头|片頭|オープニング)(\s|\d|$|[:：\-_])',
      caseSensitive: false,
    ),
    SegmentType.credits: RegExp(
      r'^\s*(ed|ending|end credits|credits|outro|片尾|エンディング)(\s|\d|$|[:：\-_])',
      caseSensitive: false,
    ),
    SegmentType.recap: RegExp(r'^\s*(recap|previously|前情提要|前情回顾|前回)', caseSensitive: false),
    SegmentType.preview: RegExp(r'^\s*(preview|next episode|预告|次回予告)', caseSensitive: false),
  };

  @override
  String get id => 'chapters';

  @override
  Future<List<SegmentCandidate>> fetch(SegmentQuery query) async {
    final chapters =
        (await source.chapters()).where((c) => c.marker == null || c.marker!.toLowerCase() == 'chapter').toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    final out = <SegmentCandidate>[];
    for (var i = 0; i < chapters.length; i++) {
      final c = chapters[i];
      for (final e in _patterns.entries) {
        if (!e.value.hasMatch(c.name)) continue;
        final next = i + 1 < chapters.length ? chapters[i + 1].start : null;
        // 片头 / 前情提要必须有结束点；片尾 / 预告是最后一章时直到文件结尾
        if (next == null && (e.key == SegmentType.intro || e.key == SegmentType.recap)) break;
        out.add(SegmentCandidate(type: e.key, start: c.start, end: next, provider: id, confidence: 0.6));
        break;
      }
    }
    return out;
  }
}
