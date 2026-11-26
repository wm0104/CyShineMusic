import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import '../../core/storage/settings_store.dart';

const albumTrackMatchesStorageKey = 'album_track_matches_v1';

String albumTrackMatchKey({
  required MusicSource source,
  required String albumId,
  required MusicInfo original,
}) => jsonEncode([source.code, albumId, original.source.code, original.id]);

class AlbumTrackMatchesNotifier extends Notifier<Map<String, MusicInfo>> {
  Future<void> _pending = Future<void>.value();

  @override
  Map<String, MusicInfo> build() {
    final raw = ref.read(sharedPreferencesProvider).getString(albumTrackMatchesStorageKey);
    final matches = <String, MusicInfo>{};
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            try {
              if (entry.key is! String || entry.value is! Map) continue;
              final value = MusicInfo.fromJson(Map<String, dynamic>.from(entry.value as Map));
              if (value.id.isNotEmpty && value.source != MusicSource.all) {
                matches[entry.key as String] = value;
              }
            } on Object {
              // Keep other valid rows when one old/corrupt record is unreadable.
            }
          }
        }
      } on FormatException {
        // An unreadable store is not an instruction to delete its disk data.
      }
    }
    return Map<String, MusicInfo>.unmodifiable(matches);
  }

  /// expected must be the exact state[key] snapshot from before opening the picker.
  /// Writes are serialized so an older route result cannot win a disk-write race.
  Future<bool> setMatch({
    required MusicSource source,
    required String albumId,
    required MusicInfo original,
    required MusicInfo replacement,
    required MusicInfo? expected,
  }) {
    final operation = _pending.then((_) async {
      if (source == MusicSource.all || original.source != source || albumId.trim().isEmpty || original.id.isEmpty || replacement.id.isEmpty || replacement.source == MusicSource.all) {
        throw ArgumentError('专辑手选记录身份无效');
      }
      final key = albumTrackMatchKey(source: source, albumId: albumId, original: original);
      if (!identical(state[key], expected)) return false;
      final next = Map<String, MusicInfo>.unmodifiable({...state, key: replacement});
      final saved = await ref.read(sharedPreferencesProvider).setString(
        albumTrackMatchesStorageKey,
        jsonEncode({for (final entry in next.entries) entry.key: entry.value.toJson()}),
      );
      if (!saved) throw StateError('专辑手选记录保存失败');
      state = next;
      return true;
    });
    _pending = operation.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return operation;
  }
}

final albumTrackMatchesProvider = NotifierProvider<AlbumTrackMatchesNotifier, Map<String, MusicInfo>>(AlbumTrackMatchesNotifier.new);
