import '../domain/models/segment.dart';
import '../domain/models/segment_settings.dart';

enum SegmentSkipActionKind { seek, nextEpisode }

class SegmentSkipAction {
  const SegmentSkipAction({required this.segment, required this.kind, required this.automatic});
  final Segment segment;
  final SegmentSkipActionKind kind;
  final bool automatic;
  Duration get target => segment.end;
}

/// Engine-independent decisions; call once per position event. Start a new
/// controller for every episode/source so completion state cannot leak.
class SegmentSkipController {
  SegmentSkipController({required this.query, required this.settings, this.hasNextEpisode = false});
  final SegmentQuery query;
  final SegmentSettings settings;
  final bool hasNextEpisode;
  List<Segment> segments = const [];
  final _handled = <String>{};
  final _manualRetry = <String>{};

  String _key(Segment segment) => '${segment.type.name}:${segment.start.inMilliseconds}:${segment.end.inMilliseconds}';

  SegmentSkipAction? at(Duration position) {
    for (final segment in segments) {
      if (!segment.contains(position) || _handled.contains(_key(segment))) {
        continue;
      }
      var mode = switch (segment.type) {
        SegmentType.intro => settings.intro,
        SegmentType.recap => settings.recap,
        SegmentType.credits => settings.credits,
        SegmentType.preview => SegmentSkipMode.off,
      };
      if (mode == SegmentSkipMode.off) continue;
      if (_manualRetry.contains(_key(segment))) mode = SegmentSkipMode.button;
      if (segment.type == SegmentType.intro &&
          query.kind == SegmentMediaKind.episode &&
          query.season == 1 &&
          query.episode == 1 &&
          settings.firstEpisodeException &&
          mode == SegmentSkipMode.auto) {
        mode = SegmentSkipMode.button;
      }
      // Bounded credits may lead to a post-credit scene. Only advance episodes
      // when the validated credits actually continue to the end of the file.
      final next = segment.type == SegmentType.credits && segment.end == query.duration && hasNextEpisode;
      return SegmentSkipAction(
        segment: segment,
        kind: next ? SegmentSkipActionKind.nextEpisode : SegmentSkipActionKind.seek,
        automatic: mode == SegmentSkipMode.auto,
      );
    }
    return null;
  }

  void markHandled(SegmentSkipAction action) => _handled.add(_key(action.segment));
  void retry(SegmentSkipAction action) {
    _handled.remove(_key(action.segment));
    _manualRetry.add(_key(action.segment));
  }
}
