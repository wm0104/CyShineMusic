import 'dart:convert' show LineSplitter;
import 'dart:math' as math;

import '../../core/models/lyric_info.dart';

class KaraokeLyrics {
  const KaraokeLyrics(this.lines);

  final List<KaraokeLyricLine> lines;

  bool get isEmpty => lines.isEmpty;
  bool get hasLineTiming => lines.isNotEmpty && lines.first.hasLineTiming;

  int activeIndex(Duration position) {
    if (!hasLineTiming) return -1;
    final ms = position.inMilliseconds;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (ms >= line.startMs && ms < line.endMs) return i;
      if (ms < line.startMs) return math.max(0, i - 1);
    }
    return lines.length - 1;
  }
}

class KaraokeLyricLine {
  const KaraokeLyricLine({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.translation,
    this.roman,
    this.words = const [],
    this.translationWords = const [],
  });

  final int startMs;
  final int endMs;
  final String text;
  final String? translation;
  final String? roman;
  final List<KaraokeWordTiming> words;
  final List<KaraokeWordTiming> translationWords;

  bool get hasLineTiming => endMs > startMs;
  bool get hasWordTiming => words.isNotEmpty;
}

class KaraokeWordTiming {
  const KaraokeWordTiming({
    required this.text,
    required this.startMs,
    required this.endMs,
  });

  final String text;
  final int startMs;
  final int endMs;

  double progressAt(int positionMs) {
    if (positionMs <= startMs) return 0;
    if (positionMs >= endMs) return 1;
    final duration = math.max(1, endMs - startMs);
    return ((positionMs - startMs) / duration).clamp(0, 1).toDouble();
  }
}

typedef _TrackLine = ({
  int startMs,
  String text,
  List<KaraokeWordTiming> words,
});

class KaraokeLyricsParser {
  const KaraokeLyricsParser._();

  static final _lineTimeExp = RegExp(
    r'\[(\d{1,3}(?::\d{1,3}){0,2}(?:\.\d{1,3})?)\]',
  );
  static final _leadingTimeFieldExp = RegExp(r'^(?:\[[\d:.]+\])+');
  static final _wordTimingExp = RegExp(r'<(\d+),(\d+)>');
  static final _absWordTagExp = RegExp(
    r'<(\d{1,3}(?::\d{1,3}){0,2}(?:\.\d{1,3})?)>',
  );

  /// Parses a single combined lyric string read back from a local file's
  /// embedded tag (written by `LyricBuilder.build`). That text may carry
  /// absolute-timestamp word tags (`<mm:ss.xxx>`, distinct
  /// from the API's `<offsetMs,durationMs>` word format) and, when
  /// translation/roman tracks were embedded too, reuses the main lyric's
  /// timestamps for those extra blocks. Lines are grouped by timestamp: the
  /// first occurrence is the main lyric (with its word tags converted into
  /// karaoke word timings), the second/third become translation/roman.
  static KaraokeLyrics parseEmbedded(String raw) {
    final groups = <int, List<_TrackLine>>{};
    for (final line in _parseTrack(raw)) {
      (groups[line.startMs] ??= []).add(line);
    }
    if (groups.isEmpty) return _untimedLyrics(raw);
    return KaraokeLyrics(
      _finalizeLineEnds([
        for (final group in groups.values)
          _combine(
            group.first,
            group.elementAtOrNull(1),
            group.elementAtOrNull(2),
          ),
      ]),
    );
  }

  /// Absolute word tags carry absolute timestamps and bracket each word:
  /// `<start>word<end><start>word<end>…`, where a shared boundary collapses
  /// the `<end><start>` pair into one tag. Every text chunk between two
  /// adjacent tags is therefore one word.
  static List<KaraokeWordTiming> _parseAbsoluteWords(String body, int lineEnd) {
    final tags = _absWordTagExp.allMatches(body).toList(growable: false);
    final words = <KaraokeWordTiming>[];
    for (var i = 0; i < tags.length; i++) {
      final next = tags.elementAtOrNull(i + 1);
      final text = body.substring(tags[i].end, next?.start);
      if (text.isEmpty) continue;
      final start = _parseTimeMs(tags[i].group(1)!);
      final end = next == null ? lineEnd : _parseTimeMs(next.group(1)!);
      if (start == null || end == null || end < start) continue;
      words.add(
        KaraokeWordTiming(
          text: text,
          startMs: start,
          endMs: math.max(start + 1, end),
        ),
      );
    }
    return words;
  }

  static KaraokeLyrics parse(LyricInfo info) {
    final main = _parseTrack(info.lyric);
    final wordTrack = _parseTrack(info.lxlyric);
    if (main.isEmpty && wordTrack.isEmpty) {
      return _untimedLyrics(
        info.lyric,
        translation: info.tlyric,
        roman: info.rlyric,
      );
    }
    final translations = {
      for (final line in _parseTrack(info.tlyric)) line.startMs: line,
    };
    final romans = {
      for (final line in _parseTrack(info.rlyric)) line.startMs: line,
    };
    final lines = <KaraokeLyricLine>[];
    final source = wordTrack.isEmpty ? main : wordTrack;
    final plainTranslations = translations.isEmpty
        ? _plainTextLines(info.tlyric)
        : const <String>[];
    for (var i = 0; i < source.length; i++) {
      final line = source[i];
      final anchor = wordTrack.isEmpty
          ? line.startMs
          : _matchingMainLineStart(main, line.text, line.startMs);
      _TrackLine? match(Map<int, _TrackLine> track) =>
          _nearestLine(track, anchor) ??
          (anchor != line.startMs ? _nearestLine(track, line.startMs) : null);
      final translation = plainTranslations.length == source.length
          ? (
              startMs: line.startMs,
              text: plainTranslations[i],
              words: const <KaraokeWordTiming>[],
            )
          : match(translations);
      lines.add(_combine(line, translation, match(romans)));
    }
    return KaraokeLyrics(_finalizeLineEnds(lines));
  }

  static final _metadata = RegExp(
    r'^\[(?:ar|al|ti|au|by|re|tool|ve|ver|length|offset|id|kuwo):[^\]]*\]$',
    caseSensitive: false,
  );

  static List<String> _plainTextLines(String? raw) {
    if (raw == null) return const [];
    final lines = <String>[];
    for (final rawLine in const LineSplitter().convert(raw)) {
      final line = rawLine.trim();
      if (_metadata.hasMatch(line)) continue;
      final text = line
          .replaceFirst(_leadingTimeFieldExp, '')
          .replaceAll(_wordTimingExp, '')
          .replaceAll(_absWordTagExp, '')
          .trim();
      if (text.isNotEmpty) lines.add(text);
    }
    return lines;
  }

  static KaraokeLyrics _untimedLyrics(
    String raw, {
    String? translation,
    String? roman,
  }) {
    final main = _plainTextLines(raw);
    final translated = _plainTextLines(translation);
    final romanized = _plainTextLines(roman);
    if (main.isEmpty) return const KaraokeLyrics([]);
    // When line counts differ, keep whole blocks instead of guessing which
    // translated sentence belongs alongside a particular original line.
    if ((translated.isNotEmpty && translated.length != main.length) ||
        (romanized.isNotEmpty && romanized.length != main.length)) {
      return KaraokeLyrics([
        KaraokeLyricLine(
          startMs: 0,
          endMs: 0,
          text: main.join('\n'),
          translation: translated.isEmpty ? null : translated.join('\n'),
          roman: romanized.isEmpty ? null : romanized.join('\n'),
        ),
      ]);
    }
    return KaraokeLyrics([
      for (var i = 0; i < main.length; i++)
        KaraokeLyricLine(
          startMs: 0,
          endMs: 0,
          text: main[i],
          translation: translated.elementAtOrNull(i),
          roman: romanized.elementAtOrNull(i),
        ),
    ]);
  }

  static KaraokeLyricLine _combine(
    _TrackLine main,
    _TrackLine? translation,
    _TrackLine? roman,
  ) {
    final endMs = [
      ...main.words,
      ...?translation?.words,
    ].fold(main.startMs + 4000, (end, word) => math.max(end, word.endMs));
    return KaraokeLyricLine(
      startMs: main.startMs,
      endMs: endMs,
      text: main.text,
      words: main.words,
      translation: translation?.text,
      translationWords: translation?.words ?? const [],
      roman: roman?.text,
    );
  }

  static List<KaraokeWordTiming> _parseWords(String body, int lineStartMs) {
    final matches = _wordTimingExp.allMatches(body).toList(growable: false);
    if (matches.isEmpty) return const [];
    final words = <KaraokeWordTiming>[];
    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      final relStart = int.tryParse(match.group(1)!);
      final duration = int.tryParse(match.group(2)!);
      if (relStart == null || duration == null) continue;
      final textStart = match.end;
      final textEnd = i + 1 < matches.length
          ? matches[i + 1].start
          : body.length;
      final text = body.substring(textStart, textEnd);
      if (text.isEmpty) continue;
      final startMs = lineStartMs + relStart;
      words.add(
        KaraokeWordTiming(
          text: text,
          startMs: startMs,
          endMs: math.max(startMs + 1, startMs + duration),
        ),
      );
    }
    return words;
  }

  static List<_TrackLine> _parseTrack(String? lrc) {
    if (lrc == null || lrc.isEmpty) return const [];
    final bodies = <int, List<String>>{};
    for (final raw in const LineSplitter().convert(lrc)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final field = _leadingTimeFieldExp.firstMatch(line);
      if (field == null) continue;
      final body = line.substring(field.end).trim();
      if (body.isEmpty) continue;
      for (final match in _lineTimeExp.allMatches(field.group(0)!)) {
        final startMs = _parseTimeMs(match.group(1)!);
        if (startMs == null) continue;
        (bodies[startMs] ??= []).add(body);
      }
    }
    final starts = bodies.keys.toList()..sort();
    final lines = <_TrackLine>[];
    for (var i = 0; i < starts.length; i++) {
      final startMs = starts[i];
      final endMs = starts.elementAtOrNull(i + 1) ?? startMs + 4000;
      for (final body in bodies[startMs]!) {
        final relative = _wordTimingExp.hasMatch(body);
        final tag = relative ? _wordTimingExp : _absWordTagExp;
        final text = body.replaceAll(tag, '').trim();
        if (text.isEmpty) continue;
        final words = relative
            ? _parseWords(body, startMs)
            : _parseAbsoluteWords(body, endMs);
        final first = tag.firstMatch(body);
        if (first != null && first.start > 0 && words.isNotEmpty) {
          final nextMs = words.first.startMs;
          words.insert(
            0,
            KaraokeWordTiming(
              text: body.substring(0, first.start),
              startMs: math.min(startMs, nextMs),
              endMs: nextMs,
            ),
          );
        }
        // Partial/malformed tags must never truncate the displayed lyric.
        final complete =
            words.isNotEmpty &&
            words.map((word) => word.text).join().trim() == text;
        lines.add((
          startMs: startMs,
          text: text,
          words: complete ? words : const [],
        ));
      }
    }
    return lines;
  }

  static List<KaraokeLyricLine> _finalizeLineEnds(
    List<KaraokeLyricLine> lines,
  ) {
    if (lines.isEmpty) return const [];
    final out = <KaraokeLyricLine>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final nextStart = i + 1 < lines.length ? lines[i + 1].startMs : null;
      final naturalEnd = nextStart == null
          ? math.max(line.endMs, line.startMs + 4000)
          : math.max(line.startMs + 1, nextStart);
      out.add(
        KaraokeLyricLine(
          startMs: line.startMs,
          endMs: naturalEnd,
          text: line.text,
          translation: line.translation,
          roman: line.roman,
          words: line.words,
          translationWords: line.translationWords,
        ),
      );
    }
    return out;
  }

  static int _matchingMainLineStart(
    List<_TrackLine> mainLines,
    String text,
    int fallbackStartMs,
  ) {
    final normalizedText = _normalizeLineText(text);
    int? bestStartMs;
    var bestDelta = 1 << 31;
    for (final line in mainLines) {
      if (_normalizeLineText(line.text) != normalizedText) continue;
      final delta = (line.startMs - fallbackStartMs).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        bestStartMs = line.startMs;
      }
    }
    return bestStartMs ?? fallbackStartMs;
  }

  static String _normalizeLineText(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  static _TrackLine? _nearestLine(Map<int, _TrackLine> lines, int startMs) {
    if (lines.isEmpty) return null;
    final exact = lines[startMs];
    if (exact != null) return exact;
    int? bestKey;
    var bestDelta = 121;
    for (final key in lines.keys) {
      final delta = (key - startMs).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        bestKey = key;
      }
    }
    return bestKey == null ? null : lines[bestKey];
  }

  static int? _parseTimeMs(String label) {
    final parts = label.split(':');
    if (parts.isEmpty || parts.length > 3) return null;
    num seconds = 0;
    for (var i = 0; i < parts.length; i++) {
      final exp = parts.length - 1 - i;
      final value = double.tryParse(parts[i]);
      if (value == null) return null;
      seconds += value * _pow60[exp];
    }
    return (seconds * 1000).round();
  }

  static const _pow60 = [1, 60, 3600];
}
