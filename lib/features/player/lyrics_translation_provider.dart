import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether lyric translations (or romanisation) are visible.
///
/// The lyrics page and the cover page lyric pane both read this, so toggling
/// the pill on one surface flips the other at the same time.
final lyricsTranslationProvider = StateProvider<bool>((ref) => true);
