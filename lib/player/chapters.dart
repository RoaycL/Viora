import '../data/emby/emby_client.dart';

/// 播放页「章节」菜单用的章节：去掉 Emby 的片头片尾标记（IntroStart / IntroEnd / CreditsStart），
/// 按开始时间排序、去掉同一时间的重复项；少于 2 个时没有意义，返回空列表
List<ServerChapter> chapterList(List<ServerChapter> all) {
  const markers = {'IntroStart', 'IntroEnd', 'CreditsStart'};
  final list = [
    for (final c in all)
      if (c.marker == null || !markers.contains(c.marker)) c,
  ]..sort((a, b) => a.start.compareTo(b.start));
  final out = <ServerChapter>[];
  for (final c in list) {
    if (out.isEmpty || out.last.start != c.start) out.add(c);
  }
  return out.length >= 2 ? out : const [];
}

/// [position] 所在的章节序号；在第一个章节之前为 -1
int currentChapterIndex(List<ServerChapter> chapters, Duration position) {
  var index = -1;
  for (var i = 0; i < chapters.length; i++) {
    if (chapters[i].start <= position) index = i;
  }
  return index;
}
