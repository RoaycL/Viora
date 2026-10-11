import 'dart:convert';
import 'dart:io';

import '../../domain/models/external_rating.dart';

class RatingsCacheEntry {
  const RatingsCacheEntry(this.fetchedAt, this.data);
  final DateTime fetchedAt;
  final RatingsData data;
  Map<String, Object?> toJson() => {'at': fetchedAt.toUtc().toIso8601String(), 'data': data.toJson()};
  factory RatingsCacheEntry.fromJson(Map<String, dynamic> json) => RatingsCacheEntry(
    DateTime.parse(json['at'] as String),
    RatingsData.fromJson(json['data'] as Map<String, dynamic>),
  );
}

abstract interface class RatingsCache {
  Future<RatingsCacheEntry?> read(String key);
  Future<void> write(String key, RatingsCacheEntry entry);
}

class MemoryRatingsCache implements RatingsCache {
  final entries = <String, RatingsCacheEntry>{};
  @override
  Future<RatingsCacheEntry?> read(String key) async => entries[key];
  @override
  Future<void> write(String key, RatingsCacheEntry entry) async {
    entries.remove(key);
    entries[key] = entry;
    while (entries.length > 512) {
      entries.remove(entries.keys.first);
    }
  }
}

/// Stores parsed ratings and hashed query/config identities, never credentials.
class FileRatingsCache implements RatingsCache {
  FileRatingsCache(this.file);
  final File file;
  Future<void> _writes = Future<void>.value();

  Future<Map<String, dynamic>> _load() async =>
      await file.exists() ? (jsonDecode(await file.readAsString()) as Map).cast<String, dynamic>() : {};

  @override
  Future<RatingsCacheEntry?> read(String key) async {
    await _writes;
    final row = (await _load())[key];
    return row is Map<String, dynamic> ? RatingsCacheEntry.fromJson(row) : null;
  }

  @override
  Future<void> write(String key, RatingsCacheEntry entry) {
    final task = _writes.then((_) async {
      Map<String, dynamic> entries;
      try {
        entries = await _load();
      } catch (_) {
        entries = {};
      }
      entries.remove(key);
      entries[key] = entry.toJson();
      while (entries.length > 512) {
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
