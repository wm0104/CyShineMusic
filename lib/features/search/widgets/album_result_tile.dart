import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/album_info.dart';
import '../../../core/models/online_collection_kind.dart';
import '../../../core/models/playlist_summary.dart';
import '../../../core/ui/container_transform.dart';
import '../../../core/ui/radio_menu.dart';
import '../../discovery/discovery_controller.dart';
import '../../discovery/widgets/discovery_playlist_cover.dart';

/// Search and artist catalogs share the same album identity and detail page.
class AlbumResultTile extends StatelessWidget {
  const AlbumResultTile({super.key, required this.album, this.fromPlayback = false,
    this.onTap, this.variants = const []});

  final AlbumInfo album;
  final bool fromPlayback;
  final VoidCallback? onTap;
  final List<AlbumInfo> variants;

  @override
  Widget build(BuildContext context) {
    if (variants.length > 1 && onTap == null) {
      return RadioMenuAnchor(
        menuId: 'album-versions-${album.source.code}-${album.id}',
        minimumWidth: 184,
        maximumWidth: 280,
        optionsBuilder: () => [
          for (var i = 0; i < variants.length; i++) RadioMenuOption(
            id: variants[i].id,
            label: _versionLabel(variants[i], i),
            selected: false,
            onSelected: () => _openAlbum(context, variants[i]),
          ),
        ],
        anchorBuilder: (context, expanded, onTapDown, onTap) =>
            _buildTile(context, onTap),
      );
    }
    return _buildTile(context, onTap ?? () => _openAlbum(context, album));
  }

  Widget _buildTile(BuildContext context, VoidCallback onTap) {
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
        if (variants.length > 1) '${variants.length} 个版本',
      ].where((part) => part.isNotEmpty).join(' · '),
        maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }

  String _versionLabel(AlbumInfo variant, int index) {
    final date = variant.publishTime;
    return [
      '版本 ${index + 1}',
      if (date != null)
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
    ].join(' · ');
  }

  void _openAlbum(BuildContext context, AlbumInfo selected) {
    // Keep playback albums inside the existing artist stack so its original
    // edge-back, player reveal and toolbar rules continue to apply.
    final scheme = Theme.of(context).colorScheme;
    final base = fromPlayback ? GoRouterState.of(context).uri.path : '/discover';
    context.push('$base/albums/${selected.source.code}/${Uri.encodeComponent(selected.id)}',
      extra: ContainerTransformExtra(
        PlaylistSummary(id: selected.id, name: selected.name, source: selected.source,
          coverUrl: selected.coverUrl, creator: selected.artistName, trackCount: selected.songCount),
        origin: ContainerTransformOrigin.capture(context, color: scheme.surface),
      ),
    );
  }
}
