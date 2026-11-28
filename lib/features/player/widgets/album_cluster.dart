import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/settings_store.dart';
import '../../shell/player_pull_scope.dart';
import '../../shell/player_transition.dart';
import '../lyrics_translation_provider.dart';
import '../player_album_navigation.dart';
import '../player_controller.dart';
import 'karaoke_lyrics_view.dart';
import 'player_palette.dart';
import 'player_cover_actions_sheet.dart';
import 'spinning_cover_art.dart';
import 'track_change_switcher.dart';

/// How many lyric rows the portrait cover page shows. The landscape pane takes
/// whatever space the artwork leaves, so it needs no row count.
const double _portraitLyricRows = 3;
/// The portrait pane sits in a narrower column than the lyrics page, so it
/// renders the same view at a slightly smaller type size.
const double _portraitLyricScale = 0.8;
const double _coverLyricsBottomInset = 20;

class AlbumPage extends ConsumerWidget {
  const AlbumPage({
    super.key,
    this.wide = false,
    this.phoneLandscape = false,
    this.onOpenLyrics,
  });

  final bool wide;
  final bool phoneLandscape;
  final VoidCallback? onOpenLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(
      playerControllerProvider.select(
        (state) => (
          track: state.track,
          lyrics: state.lyrics,
          lyricsReady: !state.lyricLoading && state.lyrics.hasLineTiming,
        ),
      ),
    );
    final miniLyricsEnabled = ref.watch(
      settingsProvider.select((settings) => settings.showMiniLyrics),
    );
    final square = ref.watch(
      settingsProvider.select((settings) => settings.squareAlbumCoverEnabled),
    );
    final lyricFontSize = ref.watch(
      settingsProvider.select((settings) => settings.lyricFontSize),
    );
    final showTranslation = ref.watch(lyricsTranslationProvider);
    final track = player.track;
    final lyrics = player.lyrics;
    final hasExtraLyrics = lyrics.lines.any((line) {
      final translation = line.translation?.trim();
      final roman = line.roman?.trim();
      return (translation != null && translation.isNotEmpty) ||
          (roman != null && roman.isNotEmpty);
    });
    final showLyrics =
        !wide && onOpenLyrics != null && miniLyricsEnabled && player.lyricsReady;
    // Height of the three-row portrait pane, derived from the lyric settings so
    // it grows with the type size instead of clipping it.
    final portraitLyricHeight =
        lyricFontSize * _portraitLyricScale * 1.75 * _portraitLyricRows + 12;

    final metadataKey = track == null
        ? 'album-metadata:loading'
        : 'album-metadata:${track.id}:${track.album}';
    // Move the landscape text up inside its existing tap target.
    final captionPadding = phoneLandscape
        ? const EdgeInsets.only(top: 8, bottom: 14)
        : EdgeInsets.only(top: wide ? 18 : 22);
    final metadata = TrackChangeSwitcher(
      transitionKey: metadataKey,
      incomingOffset: const Offset(0.12, 0),
      child: track == null
          ? SizedBox(height: captionPadding.vertical + 24)
          : _AlbumMetadata(track: track, padding: captionPadding),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        Widget artwork(double size) => _AlbumArtwork(
          track: track,
          size: size,
          wide: wide,
          showShadow: !phoneLandscape,
        );

        if (phoneLandscape) {
          // Size the square in the space left after the caption is laid out,
          // including text scaling and the phone's landscape safe insets.
          final coverWidth = math.min(
            constraints.maxHeight,
            constraints.maxWidth * 0.62,
          );
          return Stack(
            children: [
              Positioned(
                right: 0,
                width: coverWidth,
                top: 0,
                bottom: 0,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: LayoutBuilder(
                            builder: (_, bounds) => artwork(bounds.maxWidth),
                          ),
                        ),
                      ),
                      metadata,
                    ],
                  ),
                ),
              ),
              if (showLyrics)
                Positioned(
                  key: const ValueKey('player-cover-lyrics'),
                  left: 0,
                  right: coverWidth + 16,
                  top: 0,
                  bottom: 0,
                  child: KaraokeLyricsView(
                    key: const ValueKey('player-cover-lyrics-view'),
                    lyrics: lyrics,
                    showTranslation: hasExtraLyrics && showTranslation,
                    horizontalPadding: 0,
                  ),
                ),
            ],
          );
        }

        final coverScale = square ? 1.12 : 1.0;
        final maxCoverSize = (wide ? 400.0 : 360.0) * coverScale;
        final coverSize = math.min(
          maxCoverSize,
          math.min(
                constraints.maxWidth * (wide ? 0.88 : 0.86),
                constraints.maxHeight * (wide ? 0.68 : 0.62),
              ) *
              coverScale,
        );
        final resolvedCoverSize = coverSize
            .clamp(160.0, maxCoverSize)
            .toDouble();
        return Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: Transform.translate(
                offset: Offset(
                  0,
                  showLyrics ? -portraitLyricHeight * 0.5 : 0,
                ),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.symmetric(vertical: wide ? 8 : 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [artwork(resolvedCoverSize), metadata],
                  ),
                ),
              ),
            ),
            if (showLyrics)
              Positioned(
                key: const ValueKey('player-cover-lyrics'),
                left: 0,
                right: constraints.maxWidth * 0.14,
                bottom: _coverLyricsBottomInset,
                height: portraitLyricHeight,
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: const TextScaler.linear(_portraitLyricScale),
                  ),
                  child: KaraokeLyricsView(
                    key: const ValueKey('player-cover-lyrics-view'),
                    lyrics: lyrics,
                    showTranslation: false,
                    horizontalPadding: 0,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _AlbumArtwork extends ConsumerWidget {
  const _AlbumArtwork({
    required this.track,
    required this.size,
    required this.wide,
    required this.showShadow,
  });

  final PlayerTrack? track;
  final double size;
  final bool wide;
  final bool showShadow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = this.track;
    final artworkKey = track == null
        ? 'album-artwork:loading'
        : 'album-artwork:${track.id}:${track.coverUrl ?? ''}:'
              '${identityHashCode(track.coverBytes)}';
    return SizedBox.square(
      dimension: size,
      // The tap recognizer coexists with the parent's vertical
      // pull recognizer, so dragging still dismisses the page.
      child: PlayerPullHandle(
        child: Semantics(
          button: track != null,
          label: '打开当前歌曲菜单',
          child: GestureDetector(
            key: const ValueKey('player-cover-menu-button'),
            behavior: HitTestBehavior.opaque,
            onTap: track == null
                ? null
                : () => unawaited(
                    showPlayerCoverActionsSheet(
                      context,
                      ref,
                      track: track,
                      wide: wide,
                    ),
                  ),
            child: PlayerCoverAnchor(
              expanded: true,
              child: TrackChangeSwitcher(
                transitionKey: artworkKey,
                incomingOffset: Offset.zero,
                scaleBegin: 0.88,
                expand: true,
                child: track == null
                    ? _LoadingAlbumArtwork(size: size)
                    : SpinningCoverArt(
                        track: track,
                        size: size,
                        placeholder: ColoredBox(
                          color: Colors.white.withValues(alpha: 0.34),
                          child: Center(
                            child: Icon(
                              Icons.album_rounded,
                              size: 56,
                              color: playerMuted(context),
                            ),
                          ),
                        ),
                        boxShadow: showShadow
                            ? [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.16),
                                  blurRadius: 28,
                                  offset: const Offset(0, 18),
                                ),
                              ]
                            : null,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingAlbumArtwork extends ConsumerWidget {
  const _LoadingAlbumArtwork({required this.size});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final square = ref.watch(
      settingsProvider.select((settings) => settings.squareAlbumCoverEnabled),
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.22),
        shape: square ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: square
            ? BorderRadius.circular(size * kSquareCoverRadiusFactor)
            : null,
      ),
      alignment: Alignment.center,
      child: CircularProgressIndicator(
        color: playerInk(context),
        strokeWidth: 3,
      ),
    );
  }
}

class _AlbumMetadata extends ConsumerWidget {
  const _AlbumMetadata({required this.track, required this.padding});

  final PlayerTrack track;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = track.album.trim().isEmpty ? '未知专辑' : track.album.trim();
    final album = resolvePlayerAlbum(
      track,
      ref.read(playerControllerProvider.notifier).currentMusic,
    );
    final label = Padding(
      padding: padding,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: playerMuted(context).withValues(alpha: 0.78),
          fontSize: 15,
          fontWeight: FontWeight.w500,
          height: 1.15,
        ),
      ),
    );
    if (album == null) return label;
    return Semantics(
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('player-open-album'),
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            if (identical(ref.read(playerControllerProvider).track, track)) {
              openPlayerAlbum(context, album);
            }
          },
          child: label,
        ),
      ),
    );
  }
}
