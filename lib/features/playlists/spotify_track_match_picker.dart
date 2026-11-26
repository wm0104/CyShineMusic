import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import '../../core/ui/app_toast.dart';
import '../search/track_match_picker.dart';
import 'playlist_models.dart';
import 'playlist_store.dart';

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

Future<void> editSavedSpotifyTrackMatch(
  BuildContext context,
  WidgetRef ref, {
  required String playlistId,
  required PlaylistTrack track,
  required bool Function() isCurrentPlaylist,
}) async {
  final picked = await pickSpotifyTrackMatch(context, track);
  if (picked == null || !context.mounted || !isCurrentPlaylist()) return;
  try {
    final updated = await ref
        .read(localPlaylistsProvider.notifier)
        .setSpotifyTrackMatch(playlistId, expected: track, music: picked);
    if (!context.mounted || !isCurrentPlaylist()) return;
    showAppToast(
      context,
      updated ? '已更新「${track.name}」的匹配' : '歌单歌曲已变化，请重新选择',
      type: updated ? AppToastType.success : AppToastType.warning,
    );
  } catch (error) {
    if (!context.mounted || !isCurrentPlaylist()) return;
    showAppToast(context, '保存匹配失败：$error', type: AppToastType.error);
  }
}
