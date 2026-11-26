import 'dart:convert' show LineSplitter;

import '../models/enums.dart';
import '../models/lyric_format.dart';
import '../models/lyric_info.dart';

class LyricEmbedOptions {
  const LyricEmbedOptions({
    this.embedLyric = true,
    this.embedTranslatedLyric = true,
    this.embedRomanLyric = true,
    this.format = EmbeddedLyricFormat.automatic,
    this.source,
  });

  final bool embedLyric;
  final bool embedTranslatedLyric;
  final bool embedRomanLyric;
  final EmbeddedLyricFormat format;
  final MusicSource? source;

  bool get anyLyricBlock =>
      embedLyric || embedTranslatedLyric || embedRomanLyric;
}

class LyricBuilder {
  const LyricBuilder._();

  // One-or-more leading `[time]` segments — e.g. `[00:01.00]` or
  // `[00:01.00][00:30.50]`.
  static final _timeFieldExp = RegExp(r'^(?:\[[\d:.]+\])+');
  // A single time token inside a bracket: `mm:ss.xx`, `h:mm:ss.xx`.
  static final _timeExp = RegExp(r'\[([\d:.]+)\]');

  // Mirrors renderer/worker/download/lrcTool.ts in the desktop source format.
  static String build(LyricInfo info, LyricEmbedOptions options) {
    if (info.lyric.isEmpty || !options.anyLyricBlock) return '';

    final plainLyric = _fixKgLyric(info.lyric);
    final wordLyric = _fixKgLyric(info.lxlyric ?? '');
    final mainLyric = _buildMainLyric(
      plainLyric: plainLyric,
      wordLyric: wordLyric,
      format: options.format,
      source: options.source,
    );
    final alignmentLyric = plainLyric.isNotEmpty ? plainLyric : mainLyric;

    final hasT =
        options.embedTranslatedLyric && (info.tlyric?.isNotEmpty ?? false);
    final hasR = options.embedRomanLyric && (info.rlyric?.isNotEmpty ?? false);

    if (!hasT && !hasR) {
      return options.embedLyric ? mainLyric : '';
    }

    final labels = _embeddedLineAnchors(alignmentLyric, mainLyric);
    var out = mainLyric.trimRight();

    if (hasT) {
      final translation = info.tlyric!;
      final filtered = _filterExtended(
        _wordTimingExp.hasMatch(translation)
            ? _buildMainLyric(
                plainLyric: translation.replaceAll(_wordTimingExp, ''),
                wordLyric: translation,
                format: options.format,
                source: options.source,
              )
            : translation,
        labels,
      );
      if (filtered.isNotEmpty) out = '${out.trimRight()}\n\n$filtered';
    }
    if (hasR) {
      final filtered = _filterExtended(info.rlyric!, labels);
      if (filtered.isNotEmpty) out = '${out.trimRight()}\n\n$filtered';
    }
    return out;
  }

  static String _buildMainLyric({
    required String plainLyric,
    required String wordLyric,
    required EmbeddedLyricFormat format,
    required MusicSource? source,
  }) {
    switch (format) {
      case EmbeddedLyricFormat.automatic:
        if (!_sourcePrefersWordLyric(source) || wordLyric.isEmpty) {
          return plainLyric;
        }
        final enhanced = _toWordTimedLyric(wordLyric);
        return enhanced.isNotEmpty ? enhanced : plainLyric;
      case EmbeddedLyricFormat.lrc:
        return plainLyric;
      case EmbeddedLyricFormat.wordTimed:
        if (wordLyric.isEmpty) return plainLyric;
        final enhanced = _toWordTimedLyric(wordLyric);
        return enhanced.isNotEmpty ? enhanced : plainLyric;
    }
  }

  static bool _sourcePrefersWordLyric(MusicSource? source) {
    switch (source) {
      case MusicSource.tx:
      case MusicSource.kg:
      case MusicSource.kw:
        return true;
      case MusicSource.all:
      case MusicSource.wy:
      case MusicSource.mg:
      case null:
        return false;
    }
  }

  static Map<int, String> _textAtTime(String lrc) {
    final lines = <int, String>{};
    for (final raw in const LineSplitter().convert(lrc)) {
      final line = raw.trim();
      final field = _timeFieldExp.firstMatch(line);
      if (field == null) continue;
      final text = line
          .substring(field.end)
          .replaceAll(RegExp(r'<[\d:.,]+>'), '')
          .trim()
          .toLowerCase()
          .replaceAll(RegExp(r'\s+'), ' ');
      if (text.isEmpty) continue;
      for (final stamp in _timeExp.allMatches(field.group(0)!)) {
        final ms = _parseTimeMs(stamp.group(1)!);
        if (ms != null) lines[ms] = text;
      }
    }
    return lines;
  }

  // A word-timed original can start later than its plain LRC counterpart.
  // Map each original line label to its emitted label without shifting words.
  static Map<int, int> _embeddedLineAnchors(String original, String rendered) {
    final output = _textAtTime(rendered);
    final anchors = {for (final ms in output.keys) ms: ms};
    if (original == rendered) return anchors;
    final plain = <String, List<int>>{};
    for (final line in _textAtTime(original).entries) {
      (plain[line.value] ??= []).add(line.key);
    }
    for (final line in output.entries) {
      final candidates = plain[line.value];
      if (candidates == null) continue;
      final match = _nearestTime(candidates, line.key);
      if (match != null) anchors[match] = line.key;
    }
    return anchors;
  }

  static int? _nearestTime(Iterable<int> times, int ms, {int? maxDelta}) {
    int? nearest;
    for (final time in times) {
      final delta = (time - ms).abs();
      if ((maxDelta == null || delta <= maxDelta) &&
          (nearest == null || delta < (nearest - ms).abs())) {
        nearest = time;
      }
    }
    return nearest;
  }

  static String _filterExtended(String extended, Map<int, int> labels) {
    if (labels.isEmpty) return extended.trim();
    final lines = <String>[];
    for (final raw in const LineSplitter().convert(extended)) {
      final line = raw.trim();
      final field = _timeFieldExp.firstMatch(line);
      if (field == null) continue;
      final timeField = field.group(0)!;
      final text = line.substring(timeField.length).trim();
      if (text.isEmpty) continue;
      final kept = <String>[];
      for (final stamp in _timeExp.allMatches(timeField)) {
        final label = stamp.group(1)!;
        final ms = _parseTimeMs(label);
        if (ms == null) continue;
        final anchor =
            labels[ms] ?? labels[_nearestTime(labels.keys, ms, maxDelta: 120)];
        if (anchor != null) {
          kept.add(anchor == ms ? label : _formatTimeMs(anchor));
        }
      }
      if (kept.isNotEmpty) lines.add('[${kept.join('][')}]$text');
    }
    return lines.join('\n');
  }

  // Some kg lyrics arrive as `[00:01:02.345]` (4-component) where the leading
  // `00:` is a spurious hour field that breaks timestamp alignment with the
  // translation/roma tracks.
  static String _fixKgLyric(String lrc) {
    final probe = RegExp(r'\[00:\d\d:\d\d\.\d+\]');
    if (!probe.hasMatch(lrc)) return lrc;
    return lrc.replaceAllMapped(
      RegExp(r'\[00:(\d\d:\d\d\.\d+\])', multiLine: true),
      (m) => '[${m.group(1)!}',
    );
  }

  static final _wordTimingExp = RegExp(r'<(\d+),(\d+)>');

  static String _toWordTimedLyric(String lrc) {
    final lines = <String>[];
    for (final raw in const LineSplitter().convert(lrc)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final match = _timeFieldExp.firstMatch(line);
      if (match == null) {
        lines.add(line);
        continue;
      }

      final body = line.substring(match.end);
      final words = _wordTimingExp.allMatches(body).toList(growable: false);
      if (words.isEmpty) {
        lines.add(line);
        continue;
      }

      for (final stamp in _timeExp.allMatches(match.group(0)!)) {
        final lineStart = _parseTimeMs(stamp.group(1)!);
        if (lineStart == null) continue;
        lines.add(_absoluteWordLine(body, words, lineStart));
      }
    }
    return lines.join('\n');
  }

  static String _absoluteWordLine(
    String body,
    List<RegExpMatch> words,
    int lineStart,
  ) {
    final label = _formatTimeMs(lineStart);
    final buffer = StringBuffer('[$label]');
    if (words.first.start > 0) {
      buffer.write('<$label>${body.substring(0, words.first.start)}');
    }
    int? lastEnd;
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      final offset = int.tryParse(word.group(1)!);
      final duration = int.tryParse(word.group(2)!);
      if (offset == null || duration == null) {
        return '[$label]${body.replaceAll(_wordTimingExp, '')}';
      }
      final absoluteStart = lineStart + offset;
      final absoluteEnd = absoluteStart + duration;
      if (absoluteStart != lastEnd) {
        buffer.write('<${_formatTimeMs(absoluteStart)}>');
      }
      buffer.write(
        body.substring(word.end, words.elementAtOrNull(i + 1)?.start),
      );
      buffer.write('<${_formatTimeMs(absoluteEnd)}>');
      lastEnd = absoluteEnd;
    }
    return buffer.toString();
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

  static String _formatTimeMs(int timeMs) {
    final safe = timeMs < 0 ? 0 : timeMs;
    final ms = (safe % 1000).toString().padLeft(3, '0');
    final totalSeconds = safe ~/ 1000;
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds.$ms';
  }

  static const _pow60 = [1, 60, 3600];
}
