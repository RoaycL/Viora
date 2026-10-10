import '../../domain/models/segment.dart';

abstract interface class SegmentProvider {
  String get id;
  Future<List<SegmentCandidate>> fetch(SegmentQuery query);
}
