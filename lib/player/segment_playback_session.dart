import '../domain/models/segment.dart';
import '../domain/models/segment_settings.dart';
import '../domain/usecases/segment_resolver.dart';
import 'segment_skip_controller.dart';

/// Adapter for the planned PlaySession: begin after engine.open, feed position
/// events and render onPrompt. Lookup never blocks engine startup.
class SegmentPlaybackSession {
  SegmentPlaybackSession({
    required this.resolver,
    required this.seek,
    required this.nextEpisode,
    required this.onPrompt,
    this.onResolution,
    this.onActionError,
  });
  final SegmentResolver resolver;
  final Future<void> Function(Duration) seek;
  final Future<void> Function() nextEpisode;
  final void Function(SegmentSkipAction?) onPrompt;
  final void Function(SegmentResolution)? onResolution;
  final void Function(Object)? onActionError;
  int _generation = 0;
  SegmentSkipController? _controller;
  Duration _position = Duration.zero;
  bool _inFlight = false;

  void begin(SegmentQuery query, SegmentSettings settings, {bool hasNextEpisode = false}) {
    final generation = ++_generation;
    _position = Duration.zero;
    _inFlight = false;
    final controller = SegmentSkipController(query: query, settings: settings, hasNextEpisode: hasNextEpisode);
    _controller = controller;
    onPrompt(null);
    resolver
        .resolve(query)
        .then(
          (result) {
            if (generation != _generation) return;
            controller.segments = result.segments;
            onResolution?.call(result);
            onPosition(_position);
          },
          onError: (Object error) {
            if (generation == _generation) onActionError?.call(error);
          },
        );
  }

  void onPosition(Duration position) {
    _position = position;
    if (_inFlight) return;
    final action = _controller?.at(position);
    if (action != null && action.automatic) {
      activate(action);
    } else {
      onPrompt(action);
    }
  }

  Future<void> activate(SegmentSkipAction action) async {
    final controller = _controller;
    final generation = _generation;
    if (controller == null || _inFlight || controller.at(_position)?.segment != action.segment) {
      return;
    }
    _inFlight = true;
    controller.markHandled(action);
    onPrompt(null);
    try {
      if (action.kind == SegmentSkipActionKind.nextEpisode) {
        await nextEpisode();
      } else {
        await seek(action.target);
      }
    } on Exception catch (error) {
      if (generation == _generation) {
        // Present a manual retry; never loop a failing seek on every tick.
        controller.retry(action);
        onPrompt(SegmentSkipAction(segment: action.segment, kind: action.kind, automatic: false));
        onActionError?.call(error);
      }
    } finally {
      if (generation == _generation) _inFlight = false;
    }
  }

  void dispose() {
    _generation++;
    _controller = null;
    onPrompt(null);
  }
}
