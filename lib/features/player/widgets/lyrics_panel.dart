import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme/app_motion.dart';
import '../lyrics_translation_provider.dart';
import '../player_controller.dart';
import 'karaoke_lyrics_view.dart';
import 'lyric_style_sheet.dart';
import 'player_layout.dart';
import 'player_palette.dart';
import 'track_change_switcher.dart';

class LyricsPanel extends ConsumerStatefulWidget {
  const LyricsPanel({
    super.key,
    this.edgeFadeEnabled = true,
    this.horizontalPadding = playerContentInset,
  });

  final bool edgeFadeEnabled;
  final double horizontalPadding;

  @override
  ConsumerState<LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends ConsumerState<LyricsPanel> {
  @override
  Widget build(BuildContext context) {
    final showTranslation = ref.watch(lyricsTranslationProvider);
    // Everything here changes only on track switch / lyric load; the
    // per-tick `position` is consumed inside KaraokeLyricsView.
    final vm = ref.watch(
      playerControllerProvider.select(
        (s) => (
          lyricLoading: s.lyricLoading,
          lyrics: s.lyrics,
          localWithoutLyrics: s.track?.isLocal ?? false,
        ),
      ),
    );
    final localWithoutLyrics = vm.localWithoutLyrics;
    final hasTranslation = vm.lyrics.lines.any((line) {
      final translation = line.translation?.trim();
      return translation != null && translation.isNotEmpty;
    });
    final hasRoman = vm.lyrics.lines.any((line) {
      final roman = line.roman?.trim();
      return roman != null && roman.isNotEmpty;
    });
    final hasExtraLyrics = hasTranslation || hasRoman;
    final Widget child;
    final String transitionKey;
    if (vm.lyricLoading) {
      transitionKey = 'lyric-loading';
      child = const _LyricStatus(
        icon: Icons.graphic_eq_rounded,
        title: '歌词加载中',
      );
    } else if (vm.lyrics.isEmpty) {
      transitionKey = 'lyric-empty';
      child = _LyricStatus(
        icon: localWithoutLyrics
            ? Icons.library_music_rounded
            : Icons.lyrics_outlined,
        title: localWithoutLyrics ? '本地播放' : '暂无歌词',
        subtitle: localWithoutLyrics ? '未找到歌词' : null,
      );
    } else {
      final lyricsKey = identityHashCode(vm.lyrics).toString();
      transitionKey = lyricsKey;
      child = Column(
        children: [
          Expanded(
            child: KaraokeLyricsView(
              key: ValueKey('lyrics-view-$lyricsKey'),
              lyrics: vm.lyrics,
              showTranslation: hasExtraLyrics && showTranslation,
              edgeFadeEnabled: widget.edgeFadeEnabled,
              horizontalPadding: widget.horizontalPadding,
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              widget.horizontalPadding,
              4,
              widget.horizontalPadding,
              10,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _LyricSizePill(
                  key: const ValueKey('player-lyric-size-button'),
                  onTap: () => unawaited(showPlayerLyricStyleSheet(context)),
                ),
                if (hasExtraLyrics) ...[
                  const SizedBox(width: 8),
                  _LyricsTranslationToggle(
                    showTranslation: showTranslation,
                    hasTranslation: hasTranslation,
                    hasRoman: hasRoman,
                    onTap: () {
                      ref.read(lyricsTranslationProvider.notifier).state =
                          !showTranslation;
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    }
    return TrackChangeSwitcher(
      transitionKey: transitionKey,
      incomingOffset: const Offset(0.10, 0.018),
      scaleBegin: 0.985,
      expand: true,
      child: child,
    );
  }
}

class _LyricSizePill extends StatelessWidget {
  const _LyricSizePill({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = playerInk(context);
    return _LyricActionPill(
      tooltip: '歌词字号',
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.format_size_rounded,
            color: ink.withValues(alpha: 0.76),
            size: 16,
          ),
          const SizedBox(width: 6),
          Text(
            '字号',
            style: TextStyle(
              color: ink.withValues(alpha: 0.78),
              fontSize: 12,
              fontWeight: FontWeight.w500,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _LyricsTranslationToggle extends StatelessWidget {
  const _LyricsTranslationToggle({
    required this.showTranslation,
    required this.hasTranslation,
    required this.hasRoman,
    required this.onTap,
  });

  final bool showTranslation;
  final bool hasTranslation;
  final bool hasRoman;
  final VoidCallback onTap;

  String get _buttonText {
    if (!hasTranslation && hasRoman) {
      return showTranslation ? '隐藏罗马音' : '显示罗马音';
    }
    return showTranslation ? '隐藏翻译' : '显示翻译';
  }

  String get _tooltipMessage {
    if (!hasTranslation && hasRoman) {
      return showTranslation ? '隐藏罗马音歌词' : '显示罗马音歌词';
    }
    if (hasTranslation && hasRoman) {
      return showTranslation ? '隐藏歌词翻译及罗马音' : '显示歌词翻译及罗马音';
    }
    return showTranslation ? '隐藏歌词翻译' : '显示歌词翻译';
  }

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AppMotion.medium;
    final buttonText = _buttonText;
    return _LyricActionPill(
      tooltip: _tooltipMessage,
      highlighted: showTranslation,
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedRotation(
            turns: showTranslation ? 0 : -0.08,
            duration: duration,
            curve: AppMotion.emphasized,
            child: Icon(
              Icons.translate_rounded,
              color: playerInk(context).withValues(alpha: 0.76),
              size: 16,
            ),
          ),
          const SizedBox(width: 6),
          AnimatedSize(
            duration: duration,
            curve: AppMotion.emphasized,
            child: AnimatedSwitcher(
              duration: duration,
              switchInCurve: AppMotion.emphasizedDecelerate,
              switchOutCurve: AppMotion.emphasizedAccelerate,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.18),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: Text(
                buttonText,
                key: ValueKey(buttonText),
                style: TextStyle(
                  color: playerInk(context).withValues(alpha: 0.78),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  height: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LyricActionPill extends StatelessWidget {
  const _LyricActionPill({
    required this.tooltip,
    required this.onTap,
    required this.child,
    this.highlighted = true,
  });

  final String tooltip;
  final VoidCallback onTap;
  final Widget child;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AppMotion.medium;
    return Tooltip(
      message: tooltip,
      child: AnimatedContainer(
        duration: duration,
        curve: AppMotion.emphasized,
        decoration: BoxDecoration(
          color: playerInk(context).withValues(alpha: highlighted ? 0.11 : 0.06),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _LyricStatus extends StatelessWidget {
  const _LyricStatus({required this.icon, required this.title, this.subtitle});

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: playerMuted(context)),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: playerInk(context),
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: playerMuted(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
