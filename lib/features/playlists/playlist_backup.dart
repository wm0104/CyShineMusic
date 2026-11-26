import 'dart:convert';

import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import 'playlist_models.dart';

const playlistBackupFormat = 'cyshine-playlist-backup';

/// Strict at the file boundary: the normal model readers intentionally tolerate
/// legacy storage, but a damaged backup must not silently lose rows or order.
List<LocalPlaylist> decodePlaylistBackup(String text) {
  const invalid = FormatException('备份文件损坏、重复或格式不支持');
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw invalid;
  }
  if (decoded is! Map<String, dynamic> ||
      decoded['format'] != playlistBackupFormat ||
      decoded['version'] is! int || decoded['version'] != 1 || decoded['playlists'] is! List) {
    throw invalid;
  }
  final result = <LocalPlaylist>[];
  final playlistIds = <String>{};
  final origins = <String>{};
  for (final row in decoded['playlists'] as List) {
    if (row is! Map<String, dynamic> || row['version'] is! int || row['version'] != 1 ||
        !_strings(row, ['id', 'name', 'createdAt', 'updatedAt']) ||
        (row['id'] as String).trim().isEmpty ||
        (row['name'] as String).trim().isEmpty ||
        DateTime.tryParse(row['createdAt'] as String) == null ||
        DateTime.tryParse(row['updatedAt'] as String) == null ||
        row['tracks'] is! List) throw invalid;
    for (final key in ['originPlaylistId', 'originSource', 'coverUrl', 'creator', 'description']) {
      if (row[key] != null && row[key] is! String) throw invalid;
    }
    for (final key in ['originTrackCount', 'originPreviewCount']) {
      if (row[key] != null && (row[key] is! int || (row[key] as int) < 0)) throw invalid;
    }
    final identities = <String>{};
    for (final raw in row['tracks'] as List) {
      if (raw is! Map<String, dynamic> ||
          !_strings(raw, ['musicId', 'name', 'singer', 'albumName', 'source', 'quality'])) throw invalid;
      for (final key in ['localPath', 'picUrl', 'playlistEntryKey']) {
        if (raw[key] != null && raw[key] is! String) throw invalid;
      }
      if (raw['spotifyMatchIsManual'] != null && raw['spotifyMatchIsManual'] is! bool) throw invalid;
      if (raw['musicInfo'] != null) {
        if (raw['musicInfo'] is! Map<String, dynamic>) throw invalid;
        final music = raw['musicInfo'] as Map<String, dynamic>;
        if (!_strings(music, ['id', 'name', 'singer', 'source']) || music['meta'] is! Map) throw invalid;
        if (raw['spotify'] == null) {
          // A local file without musicInfo has no online identity to validate.
          // For online payloads, do not let permissive model parsing turn an
          // unknown platform into `all` or play a different row's platform/ID.
          final outerSource = MusicSource.tryFromCode(raw['source'] as String);
          final innerSource = MusicSource.tryFromCode(music['source'] as String);
          if (outerSource == null || outerSource == MusicSource.all ||
              innerSource == null || innerSource == MusicSource.all ||
              outerSource != innerSource ||
              (raw['musicId'] as String).trim().isEmpty || raw['musicId'] != music['id']) {
            throw invalid;
          }
        }
        try { MusicInfo.fromJson(music); } catch (_) { throw invalid; }
      }
      if (raw['spotify'] != null) {
        final spotify = raw['spotify'];
        if (spotify is! Map<String, dynamic> ||
            !_strings(spotify, ['uri', 'title', 'artist', 'type']) ||
            (spotify['uri'] as String).isEmpty ||
            spotify['occurrence'] is! int || (spotify['occurrence'] as int) < 0 ||
            (spotify['durationMs'] != null && spotify['durationMs'] is! int) ||
            (spotify['explicit'] != null && spotify['explicit'] is! bool)) throw invalid;
      }
      final track = PlaylistTrack.tryFromJson(raw);
      if (track == null || !identities.add(track.identityKey) ||
          (raw['spotifyMatchIsManual'] == true && (track.spotify == null || track.musicInfo == null))) throw invalid;
    }
    for (final key in ['customTrackOrder', 'onlineTrackIds', 'movedOutTrackIds']) {
      final values = row[key];
      if (values == null) continue;
      if (values is! List || values.any((v) => v is! String || v.trim().isEmpty) ||
          values.toSet().length != values.length) throw invalid;
      if (key == 'customTrackOrder' &&
          (values.length != identities.length || !identities.containsAll(values))) throw invalid;
    }
    final providers = row['movedOutTrackProviders'];
    if (providers != null && (providers is! Map<String, dynamic> ||
        providers.values.any((v) => v != null && v is! String))) throw invalid;
    final playlist = LocalPlaylist.tryFromJson(row);
    if (playlist == null || !playlistIds.add(playlist.id)) throw invalid;
    final origin = backupPlaylistOrigin(playlist);
    if (origin != null && !origins.add(origin)) throw invalid;
    result.add(playlist);
  }
  return result;
}

bool _strings(Map<String, dynamic> row, List<String> keys) =>
    keys.every((key) => row[key] is String);

String? backupPlaylistOrigin(LocalPlaylist playlist) {
  final id = playlist.originPlaylistId;
  final source = playlist.originSourceCode;
  return id == null || source == null ? null : '$source\u0000$id';
}
