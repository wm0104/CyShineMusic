import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/music_api.dart';
import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import '../../core/models/playlist_summary.dart';
import '../../core/ui/container_transform.dart';
import '../shell/player_pull_scope.dart';
import 'player_models.dart';

String _albumNameForComparison(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

PlaylistSummary? resolvePlayerAlbum(PlayerTrack? track, MusicInfo? music) {
  if (track == null ||
      music == null ||
      !MusicApi.albumSources.contains(music.source)) {
    return null;
  }
  final name = track.album.trim();
  if (name.isEmpty ||
      name == '未知专辑' ||
      _albumNameForComparison(name) !=
          _albumNameForComparison(music.albumName)) {
    return null;
  }
  final raw = music.meta.albumId;
  String? id;
  if (music.source == MusicSource.tx) {
    // The QQ endpoint takes an album MID. Older imports may have stored
    // only a numeric album ID, which identifies a different QQ resource.
    id = music.meta.albumMid?.trim();
    if ((id == null || id.isEmpty) &&
        raw is String &&
        RegExp(r'^[0-9A-Za-z]{14}$').hasMatch(raw) &&
        RegExp(r'[A-Za-z]').hasMatch(raw)) {
      id = raw;
    }
    if (id == null ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id) ||
        const {'0', '-1', 'null', 'undefined'}.contains(id.toLowerCase())) {
      return null;
    }
  } else {
    if (raw is! String && raw is! int) return null;
    id = raw.toString().trim();
    if (!RegExp(r'^[1-9][0-9]*$').hasMatch(id)) return null;
  }
  return PlaylistSummary(
    id: id,
    name: name,
    source: music.source,
    coverUrl: track.coverUrl ?? music.meta.picUrl,
    creator: track.artist,
  );
}

void openPlayerAlbum(BuildContext context, PlaylistSummary album) {
  final pull = PlayerPullScope.maybeOf(context);
  if (pull == null) return;
  final stack = GoRouter.of(context).routerDelegate.currentConfiguration;
  final player = stack.lastOrNull;
  if (player == null || player.matchedLocation != '/player') return;

  // Peek beneath this player without popping anything. The remembered tab
  // URI can differ, for example when an album was opened inside artist credits.
  final below = stack.remove(player).lastOrNull;
  final segments = below == null
      ? null
      : Uri.parse(below.matchedLocation).pathSegments;
  final sameAlbum = switch (segments) {
    ['discover', 'albums', final source, final id] ||
    ['player', 'albums', final source, final id] ||
    [
      'player',
      'artists',
      _,
      _,
      'albums',
      final source,
      final id,
    ] => source == album.source.code && id == album.id,
    _ => false,
  };
  if (sameAlbum) {
    pull.onClose();
    return;
  }

  pull.onClose(
    '/player/albums/${album.source.code}/${Uri.encodeComponent(album.id)}',
    ContainerTransformExtra(
      album,
      origin: ContainerTransformOrigin.capture(
        context,
        color: Theme.of(context).colorScheme.surface,
      ),
    ),
  );
}
