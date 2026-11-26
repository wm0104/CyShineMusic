import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/album_info.dart';
import '../../../core/models/online_collection_kind.dart';
import '../../../core/models/playlist_summary.dart';
import '../../../core/ui/container_transform.dart';
import '../../discovery/discovery_controller.dart';
import '../../discovery/widgets/discovery_playlist_cover.dart';

/// Search and artist catalogs share the same album identity and detail page.
class AlbumResultTile extends StatelessWidget {
  const AlbumResultTile({super.key, required this.album, this.fromPlayback = false, this.onTap});

  final AlbumInfo album;
  final bool fromPlayback;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      key: ValueKey('album-${album.source.code}-${album.id}'),
      minTileHeight: 62,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      horizontalTitleGap: 8,
      leading: Hero(
        tag: onlinePlaylistArtworkHeroTag(album.source, album.id, kind: OnlineCollectionKind.album),
        createRectTween: containerTransformHeroRectTween,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox.square(dimension: 44,
            child: DiscoveryPlaylistCover(url: album.coverUrl, size: 44)),
        ),
      ),
      title: Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface)),
      subtitle: Text([
        album.artistName, album.source.label,
        if (album.songCount != null) '${album.songCount} 首',
      ].where((part) => part.isNotEmpty).join(' · '),
        maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap ?? () {
        // Keep playback albums inside the existing artist stack so its original
        // edge-back, player reveal and toolbar rules continue to apply.
        final base = fromPlayback ? GoRouterState.of(context).uri.path : '/discover';
        context.push('$base/albums/${album.source.code}/${Uri.encodeComponent(album.id)}',
          extra: ContainerTransformExtra(
            PlaylistSummary(id: album.id, name: album.name, source: album.source,
              coverUrl: album.coverUrl, creator: album.artistName, trackCount: album.songCount),
            origin: ContainerTransformOrigin.capture(context, color: scheme.surface),
          ),
        );
      },
    );
  }
}
