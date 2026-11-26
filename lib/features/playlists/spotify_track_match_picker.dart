import 'package:flutter/widgets.dart';

import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import '../search/track_match_picker.dart';
import 'playlist_models.dart';

Future<MusicInfo?> pickSpotifyTrackMatch(
  BuildContext context,
  PlaylistTrack track, {
  MusicSource? initialSource,
}) async {
  final original = track.spotify;
  if (original == null) return null;
  return showTrackMatchPicker(
    context,
    title: original.title,
    artist: original.artist,
    initialSource: initialSource ?? track.musicInfo?.source ?? MusicSource.all,
  );
}
