import 'dart:convert';
import 'dart:io';

import '../../domain/models/segment.dart';
import '../../domain/usecases/segment_resolver.dart';
import 'segment_http.dart';

class MemorySegmentCache implements SegmentCache {
  final _entries = <String, SegmentCacheEntry>{};
  @override
  Future<SegmentCacheEntry?> read(String key) async => _entries[key];
  @override
  Future<void> write(String key, SegmentCacheEntry entry) async {
    _entries[key] = entry;
  }
}

/// A bounded cache until the planned drift database is introduced. Contains
/// timestamps and hashed identities only; provider API keys are never written.
class FileSegmentCache implements SegmentCache {
  FileSegmentCache(this.file);
  final File file;
  Future<void> _writes = Future<void>.value();

  Future<Map<String, dynamic>> _load() async {
    if (!await file.exists()) return {};
    return segmentObject(jsonDecode(await file.readAsString()));
  }

  @override
  Future<SegmentCacheEntry?> read(String key) async {
    await _writes;
    final value = (await _load())[key];
    if (value is! Map<String, dynamic>) return null;
    try {
      return SegmentCacheEntry(
        DateTime.parse(value['fetched_at'] as String),
        (value['candidates'] as List).map((v) => SegmentCandidate.fromJson(v as Map<String, dynamic>)).toList(),
      );
    } on Object {
      throw const FormatException('Invalid segment cache entry');
    }
  }

  @override
  Future<void> write(String key, SegmentCacheEntry entry) {
    final task = _writes.then((_) async {
      Map<String, dynamic> entries;
      try {
        entries = await _load();
      } on Exception {
        entries = {};
      }
      entries.remove(key);
      entries[key] = {
        'fetched_at': entry.fetchedAt.toUtc().toIso8601String(),
        'candidates': entry.candidates.map((c) => c.toJson()).toList(),
      };
      while (entries.length > 256) {
        entries.remove(entries.keys.first);
      }
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(entries), flush: true);
      await temporary.rename(file.path);
    });
    _writes = task.catchError((Object _) {});
    return task;
  }
}
