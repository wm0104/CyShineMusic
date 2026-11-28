import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/settings_store.dart';
import '../../settings/widgets/settings_number_control.dart';

/// Lyric font controls opened from the lyrics page itself. Values are written
/// as soon as a control commits, so the real lyrics above the sheet resize
/// live instead of the user guessing from a detached preview.
Future<void> showPlayerLyricStyleSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      // Keep the lyrics above readable: this sheet adjusts what it covers.
      barrierColor: Colors.transparent,
      builder: (_) => const _PlayerLyricStyleSheet(),
    );

class _PlayerLyricStyleSheet extends ConsumerStatefulWidget {
  const _PlayerLyricStyleSheet();

  @override
  ConsumerState<_PlayerLyricStyleSheet> createState() =>
      _PlayerLyricStyleSheetState();
}

class _PlayerLyricStyleSheetState extends ConsumerState<_PlayerLyricStyleSheet> {
  final _sizeKey = GlobalKey<SettingsNumberControlState>();
  final _weightKey = GlobalKey<SettingsNumberControlState>();
  final _translationSizeKey = GlobalKey<SettingsNumberControlState>();
  final _translationWeightKey = GlobalKey<SettingsNumberControlState>();

  Future<void> _apply({
    double? weight,
    double? size,
    double? translationWeight,
    double? translationSize,
  }) {
    final settings = ref.read(settingsProvider);
    return ref
        .read(settingsProvider.notifier)
        .setLyricFontStyle(
          weight: weight ?? settings.lyricFontWeight,
          size: size ?? settings.lyricFontSize,
          translationWeight:
              translationWeight ?? settings.lyricTranslationFontWeight,
          translationSize: translationSize ?? settings.lyricTranslationFontSize,
        );
  }

  void _reset() {
    _sizeKey.currentState?.setValue(kLyricFontSizeDefault);
    _weightKey.currentState?.setValue(kLyricFontWeightDefault);
    _translationSizeKey.currentState?.setValue(
      kLyricTranslationFontSizeDefault,
    );
    _translationWeightKey.currentState?.setValue(
      kLyricTranslationFontWeightDefault,
    );
    unawaited(
      _apply(
        weight: kLyricFontWeightDefault,
        size: kLyricFontSizeDefault,
        translationWeight: kLyricTranslationFontWeightDefault,
        translationSize: kLyricTranslationFontSizeDefault,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final media = MediaQuery.of(context);
    final isDefault =
        settings.lyricFontWeight == kLyricFontWeightDefault &&
        settings.lyricFontSize == kLyricFontSizeDefault &&
        settings.lyricTranslationFontWeight ==
            kLyricTranslationFontWeightDefault &&
        settings.lyricTranslationFontSize ==
            kLyricTranslationFontSizeDefault;
    final divider = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Divider(
        height: 1,
        color: scheme.outlineVariant.withValues(alpha: 0.4),
      ),
    );
    return AnimatedPadding(
      key: const ValueKey('player-lyric-style-sheet'),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: media.size.height * 0.45),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                fit: FlexFit.loose,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '歌词字号',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: isDefault ? null : _reset,
                            icon: const Icon(
                              Icons.restart_alt_rounded,
                              size: 18,
                            ),
                            label: const Text('重置'),
                          ),
                        ],
                      ),
                      Text(
                        '边调边生效，上方歌词会同步变化',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: scheme.outlineVariant.withValues(
                              alpha: 0.45,
                            ),
                          ),
                        ),
                        child: Column(
                          children: [
                            SettingsNumberControl(
                              key: _sizeKey,
                              icon: Icons.format_size_rounded,
                              label: '原歌词大小',
                              value: settings.lyricFontSize,
                              min: kLyricFontSizeMin,
                              max: kLyricFontSizeMax,
                              step: 1,
                              continuousLabel: (value) =>
                                  value.round().toString(),
                              commitOnRelease: false,
                              onChanged: (value) => unawaited(
                                _apply(size: value.roundToDouble()),
                              ),
                            ),
                            divider,
                            SettingsNumberControl(
                              key: _weightKey,
                              icon: Icons.format_bold_rounded,
                              label: '字体粗细',
                              value: settings.lyricFontWeight,
                              min: kLyricFontWeightMin,
                              max: kLyricFontWeightMax,
                              // Unquantised and live: the thumb tracks the
                              // finger and every rounded value lands at once,
                              // so the lyrics above resize while dragging.
                              step: 10,
                              continuousLabel: (value) =>
                                  value.round().toString(),
                              commitOnRelease: false,
                              onChanged: (value) => unawaited(
                                _apply(weight: value.roundToDouble()),
                              ),
                            ),
                            divider,
                            SettingsNumberControl(
                              key: _translationSizeKey,
                              icon: Icons.format_size_rounded,
                              label: '译文大小',
                              value: settings.lyricTranslationFontSize,
                              min: kLyricTranslationFontSizeMin,
                              max: kLyricTranslationFontSizeMax,
                              step: 1,
                              continuousLabel: (value) =>
                                  value.round().toString(),
                              commitOnRelease: false,
                              onChanged: (value) => unawaited(
                                _apply(translationSize: value.roundToDouble()),
                              ),
                            ),
                            divider,
                            SettingsNumberControl(
                              key: _translationWeightKey,
                              icon: Icons.format_bold_rounded,
                              label: '字体粗细',
                              value: settings.lyricTranslationFontWeight,
                              min: kLyricFontWeightMin,
                              max: kLyricFontWeightMax,
                              step: 10,
                              continuousLabel: (value) =>
                                  value.round().toString(),
                              commitOnRelease: false,
                              onChanged: (value) => unawaited(
                                _apply(
                                  translationWeight: value.roundToDouble(),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
