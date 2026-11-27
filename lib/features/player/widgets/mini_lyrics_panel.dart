import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/settings_store.dart';
import '../../../theme/app_motion.dart';
import '../lyric_parser.dart';
import '../player_controller.dart';
import 'karaoke_line_text.dart';
import 'player_layout.dart';

/// Blur applied directly to the previous and next lyric text. Increase this
/// value for a stronger effect; the active line always stays sharp.
const double miniLyricsInactiveBlurSigma = 0.45;

const double _miniLyricLineExtent = 22;
const int _miniLyricVisibleLineCount = 3;
const Duration _miniLyricScrollDuration = Duration(milliseconds: 380);
// Breathing room INSIDE the list viewport so the first/last row's blur halo
// fades out before reaching the viewport clip instead of being sliced flat
// against it. The panel padding below hands back the same amount, so text
// keeps its exact on-screen position and the window math is untouched:
// row i starts at bleed + i*extent, and the existing `windowStart * extent`
// scroll target leaves the top row exactly `bleed` inside the viewport.
const double _miniLyricBlurBleed = 4;
const double _miniLyricViewportExtent =
    _miniLyricVisibleLineCount * _miniLyricLineExtent + _miniLyricBlurBleed;

class MiniLyricsPanel extends ConsumerStatefulWidget {
  const MiniLyricsPanel({super.key, required this.onOpenLyrics});

  final VoidCallback onOpenLyrics;

  @override
  ConsumerState<MiniLyricsPanel> createState() => _MiniLyricsPanelState();
}

class _MiniLyricsPanelState extends ConsumerState<MiniLyricsPanel> {
  // Same clock plumbing as KaraokeLyricsView: playback time reaches the
  // karaoke painter through listenables, so progress never rebuilds the panel.
  late final ValueNotifier<int> _anchorMs;
  final ValueNotifier<bool> _playing = ValueNotifier(false);
  final ValueNotifier<bool> _buffering = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    final initial = ref.read(playerControllerProvider);
    _anchorMs = ValueNotifier<int>(initial.position.inMilliseconds);
    _playing.value = initial.playing;
    _buffering.value = initial.buffering;
    ref.listenManual(playerControllerProvider.select((s) => s.position), (
      previous,
      next,
    ) {
      _anchorMs.value = next.inMilliseconds;
    });
    ref.listenManual(playerControllerProvider.select((s) => s.playing), (
      previous,
      next,
    ) {
      _playing.value = next;
    });
    ref.listenManual(playerControllerProvider.select((s) => s.buffering), (
      previous,
      next,
    ) {
      _buffering.value = next;
    });
  }

  @override
  void dispose() {
    _anchorMs.dispose();
    _playing.dispose();
    _buffering.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(
      settingsProvider.select((settings) => settings.showMiniLyrics),
    );
    if (!enabled) return const SizedBox.shrink();
    final vm = ref.watch(
      playerControllerProvider.select(
        (state) => (
          lyrics: state.lyrics,
          activeIndex: state.lyricLoading || state.lyrics.isEmpty
              ? -1
              : state.lyrics.activeIndex(state.position),
        ),
      ),
    );
    if (vm.activeIndex < 0 || vm.lyrics.isEmpty) {
      return const SizedBox.shrink();
    }

    return Semantics(
      button: true,
      label: '打开歌词页面',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Material(
          key: const ValueKey('player-mini-lyrics-surface'),
          color: Colors.transparent,
          child: InkWell(
            key: const ValueKey('player-mini-lyrics'),
            onTap: widget.onOpenLyrics,
            child: SizedBox(
              height: 84,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: playerProgressTrackInset - _miniLyricBlurBleed,
                  vertical: 9 - _miniLyricBlurBleed,
                ),
                child: SizedBox(
                  height: _miniLyricViewportExtent,
                  child: _MiniLyricsScroller(
                    lyrics: vm.lyrics,
                    activeIndex: vm.activeIndex,
                    anchorMs: _anchorMs,
                    playing: _playing,
                    buffering: _buffering,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniLyricsScroller extends StatefulWidget {
  const _MiniLyricsScroller({
    required this.lyrics,
    required this.activeIndex,
    required this.anchorMs,
    required this.playing,
    required this.buffering,
  });

  final KaraokeLyrics lyrics;
  final int activeIndex;
  final ValueListenable<int> anchorMs;
  final ValueListenable<bool> playing;
  final ValueListenable<bool> buffering;

  @override
  State<_MiniLyricsScroller> createState() => _MiniLyricsScrollerState();
}

class _MiniLyricsScrollerState extends State<_MiniLyricsScroller> {
  late final ScrollController _controller;
  late int _windowStart;
  int _scrollGeneration = 0;

  @override
  void initState() {
    super.initState();
    _windowStart = _resolveWindowStart();
    _controller = ScrollController(
      initialScrollOffset: _windowStart * _miniLyricLineExtent,
    );
  }

  @override
  void didUpdateWidget(covariant _MiniLyricsScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextStart = _resolveWindowStart();
    final lyricsChanged = !identical(widget.lyrics, oldWidget.lyrics);
    if (!lyricsChanged && nextStart == _windowStart) return;
    _windowStart = nextStart;
    _scheduleScroll(animate: !lyricsChanged);
  }

  @override
  void dispose() {
    _scrollGeneration++;
    _controller.dispose();
    super.dispose();
  }

  int _resolveWindowStart() {
    final lineCount = widget.lyrics.lines.length;
    final maxStart = (lineCount - _miniLyricVisibleLineCount).clamp(
      0,
      lineCount,
    );
    return (widget.activeIndex - 1).clamp(0, maxStart);
  }

  void _scheduleScroll({required bool animate}) {
    final generation = ++_scrollGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _scrollGeneration ||
          !_controller.hasClients) {
        return;
      }
      final target = (_windowStart * _miniLyricLineExtent).clamp(
        0.0,
        _controller.position.maxScrollExtent,
      );
      if (!animate || MediaQuery.disableAnimationsOf(context)) {
        _controller.jumpTo(target);
        return;
      }
      unawaited(
        _controller.animateTo(
          target,
          duration: _miniLyricScrollDuration,
          curve: AppMotion.emphasized,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = widget.lyrics.lines;
    final blurDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _miniLyricScrollDuration;
    return ListView.builder(
      key: const ValueKey('player-mini-lyrics-scroll'),
      controller: _controller,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(_miniLyricBlurBleed),
      itemExtent: _miniLyricLineExtent,
      // ignore: deprecated_member_use
      cacheExtent: 0,
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final active = index == widget.activeIndex;
        final targetSigma = active ? 0.0 : miniLyricsInactiveBlurSigma;
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: targetSigma),
          duration: blurDuration,
          curve: AppMotion.emphasized,
          child: Align(
            alignment: Alignment.centerLeft,
            child: _MiniLyricLine(
              key: ValueKey('player-mini-lyric-line-$index'),
              line: lines[index],
              active: active,
              anchorMs: widget.anchorMs,
              playing: widget.playing,
              buffering: widget.buffering,
              style: TextStyle(
                color: active
                    ? scheme.onSurface
                    : scheme.onSurfaceVariant.withValues(alpha: 0.72),
                fontSize: active ? 14 : 12.5,
                fontWeight: FontWeight.w400,
                height: 1.15,
              ),
            ),
          ),
          builder: (context, sigma, child) => ImageFiltered(
            key: ValueKey('player-mini-lyric-blur-$index'),
            // Decal so the blur halo fades past the text bounds instead of
            // clamp's hard seam at the glyph edges.
            imageFilter: ImageFilter.blur(
              sigmaX: sigma,
              sigmaY: sigma,
              tileMode: TileMode.decal,
            ),
            enabled: sigma > 0.05,
            child: child,
          ),
        );
      },
    );
  }
}

/// One row of the mini panel. The active row reuses the shared karaoke
/// renderer, so it fills per word exactly like the full lyrics page; the
/// neighbouring rows stay plain text so only the current line sweeps.
class _MiniLyricLine extends StatelessWidget {
  const _MiniLyricLine({
    super.key,
    required this.line,
    required this.active,
    required this.anchorMs,
    required this.playing,
    required this.buffering,
    required this.style,
  });

  final KaraokeLyricLine line;
  final bool active;
  final ValueListenable<int> anchorMs;
  final ValueListenable<bool> playing;
  final ValueListenable<bool> buffering;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      line.text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    if (!active) return text;

    return DefaultTextStyle(
      key: const ValueKey('player-mini-lyric-active-style'),
      style: style,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The karaoke paragraph has no maxLines, so a line that cannot fit
          // the 22px row keeps the plain ellipsised text instead of wrapping
          // over its neighbours.
          if (!_fitsSingleLine(context, constraints.maxWidth)) return text;
          return KaraokeLineText(
            line: line,
            anchorMs: anchorMs,
            playing: playing,
            buffering: buffering,
            active: true,
          );
        },
      ),
    );
  }

  bool _fitsSingleLine(BuildContext context, double maxWidth) {
    if (!maxWidth.isFinite) return true;
    final painter = TextPainter(
      text: TextSpan(text: line.text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width <= maxWidth;
  }
}
