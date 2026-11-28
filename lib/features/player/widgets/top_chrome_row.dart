import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shell/player_pull_scope.dart';
import '../player_controller.dart';
import 'player_palette.dart';
import 'track_change_switcher.dart';

class TopChromeRow extends ConsumerWidget {
  const TopChromeRow({
    super.key,
    this.onOpenArtist,
    this.openingArtist = false,
  });
  final VoidCallback? onOpenArtist;
  final bool openingArtist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trackMetadata = ref.watch(
      playerControllerProvider.select(
        (s) =>
            (id: s.track?.id, title: s.track?.title, artist: s.track?.artist),
      ),
    );
    return PlayerPullHandle(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 8, 12, 4),
        child: Row(
          children: [
            Expanded(
              child: TrackChangeSwitcher(
                transitionKey:
                    'top-title:${trackMetadata.id ?? 'loading'}:'
                    '${trackMetadata.title ?? ''}:'
                    '${trackMetadata.artist ?? ''}',
                alignment: Alignment.centerLeft,
                child:
                    trackMetadata.title != null &&
                        trackMetadata.title!.trim().isNotEmpty
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            key: const ValueKey('player-header-title'),
                            trackMetadata.title!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: playerInk(context),
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                              height: 1.05,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              key: const ValueKey('player-open-artist'),
                              borderRadius: BorderRadius.circular(4),
                              onTap: openingArtist ? null : onOpenArtist,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(minHeight: 28),
                                child: Align(alignment: Alignment.centerLeft,
                                  child: Text(
                                    key: const ValueKey('player-header-artist'),
                                    trackMetadata.artist?.trim().isNotEmpty == true
                                        ? trackMetadata.artist!.trim() : '未知歌手',
                                    maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: playerMuted(context).withValues(alpha: 0.78),
                                      fontSize: 13, fontWeight: FontWeight.w400, height: 1.05,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    : const SizedBox(height: 36),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
