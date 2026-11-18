import 'package:flutter_test/flutter_test.dart';
import 'package:viora/data/media/media_models.dart';
import 'package:viora/data/media/server_registry.dart';

void main() {
  MediaItem ep(String id, {int minutes = 0, bool played = false}) => MediaItem(
    serverId: 's',
    id: id,
    kind: MediaKind.episode,
    name: id,
    position: Duration(minutes: minutes),
    played: played,
  );

  Map<String, (MediaItem, DateTime)> local(List<MediaItem> items) => {
    for (final it in items) '${it.serverId}/${it.id}': (it, DateTime.now()),
  };

  test('本机刚播放过的覆盖服务器的旧进度；看完的保留；新开始看的加进来', () {
    final server = [ep('a', minutes: 5), ep('b', minutes: 10), ep('c', minutes: 3)];
    final merged = mergeLocalPlays(
      server,
      local([
        ep('a', minutes: 25), // 服务器还是旧的 5 分钟
        ep('b', minutes: 44, played: true), // 看完了
        ep('d', minutes: 2), // 刚开始看，服务器还没刷新回来
      ]),
    );
    expect(
      [for (final it in merged) (it.id, it.position.inMinutes, it.played)],
      [('a', 25, false), ('b', 44, true), ('c', 3, false), ('d', 2, false)],
    );
  });

  test('没有本机记录时原样返回', () {
    final server = [ep('a', minutes: 5)];
    expect(identical(mergeLocalPlays(server, const {}), server), isTrue);
  });
}
