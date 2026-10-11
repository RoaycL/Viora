import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/models/segment.dart';

/// 手动标记的片头 / 片尾（docs/05-metadata-and-segments.md §手动标记）。
///
/// 剧集按「剧 + 季」保存，同一季后面的集自动沿用；电影按单部保存。
/// 片尾记录「距离结尾多远」，每集时长略有不同时也能对上。
class ManualMark {
  const ManualMark({this.introStart, this.introEnd, this.creditsFromEnd});

  final Duration? introStart;
  final Duration? introEnd;

  /// 片尾开始处距离文件结尾的时长
  final Duration? creditsFromEnd;

  bool get isEmpty => introEnd == null && creditsFromEnd == null;

  ManualMark copyWith({
    Duration? introStart,
    Duration? introEnd,
    Duration? creditsFromEnd,
    bool clearIntro = false,
    bool clearCredits = false,
  }) => ManualMark(
    introStart: clearIntro ? null : (introStart ?? this.introStart),
    introEnd: clearIntro ? null : (introEnd ?? this.introEnd),
    creditsFromEnd: clearCredits ? null : (creditsFromEnd ?? this.creditsFromEnd),
  );

  /// 换算成这一集（时长 [duration]）的片段
  List<Segment> segmentsFor(Duration duration) {
    final list = <Segment>[];
    final end = introEnd;
    if (end != null && end > Duration.zero && end < duration) {
      final start = introStart != null && introStart! < end ? introStart! : Duration.zero;
      list.add(Segment(type: SegmentType.intro, start: start, end: end, provider: 'manual', confidence: 1));
    }
    final fromEnd = creditsFromEnd;
    if (fromEnd != null && fromEnd > Duration.zero && fromEnd < duration) {
      final start = duration - fromEnd;
      // 片尾不能早于片头结束
      if (end == null || start > end) {
        list.add(Segment(type: SegmentType.credits, start: start, end: duration, provider: 'manual', confidence: 1));
      }
    }
    return list;
  }

  Map<String, Object?> toJson() => {
    'introStart': introStart?.inMilliseconds,
    'introEnd': introEnd?.inMilliseconds,
    'creditsFromEnd': creditsFromEnd?.inMilliseconds,
  };

  factory ManualMark.fromJson(Map<String, dynamic> j) {
    Duration? d(String k) => j[k] is int ? Duration(milliseconds: j[k] as int) : null;
    return ManualMark(introStart: d('introStart'), introEnd: d('introEnd'), creditsFromEnd: d('creditsFromEnd'));
  }
}

/// 手动标记的存取（shared_preferences，一个 JSON 对象）
abstract final class ManualSegmentStore {
  static const _key = 'viora.manualSegments.v1';

  /// 剧集：剧 + 季；电影：单部
  static String keyOf(SegmentQuery q) =>
      q.kind == SegmentMediaKind.episode ? '${q.titleKey}#s${q.season ?? 0}' : q.titleKey;

  static Future<Map<String, dynamic>> _all() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      return raw == null ? {} : jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static Future<ManualMark?> load(SegmentQuery q) async {
    final j = (await _all())[keyOf(q)];
    return j is Map<String, dynamic> ? ManualMark.fromJson(j) : null;
  }

  static Future<void> save(SegmentQuery q, ManualMark mark) async {
    final all = await _all();
    if (mark.isEmpty) {
      all.remove(keyOf(q));
    } else {
      all[keyOf(q)] = mark.toJson();
    }
    await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(all));
  }

  static Future<int> count() async => (await _all()).length;

  static Future<void> clearAll() async => (await SharedPreferences.getInstance()).remove(_key);
}

/// 手动标记优先：同类型的片段用手动的替换，其他类型保留数据源的结果
List<Segment> mergeManualSegments(List<Segment> resolved, List<Segment> manual) {
  if (manual.isEmpty) return resolved;
  final types = {for (final m in manual) m.type};
  return [...resolved.where((s) => !types.contains(s.type)), ...manual]..sort((a, b) => a.start.compareTo(b.start));
}
