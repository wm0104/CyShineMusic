import '../models/enums.dart';
import '../../features/equalizer/equalizer_store.dart';
import '../../theme/color_style.dart';
import '../../theme/custom_theme.dart';
import 'settings_store.dart';

/// Strict boundary for optional manual-backup preferences, not live sync.
/// Returns only known keys; absence preserves the local preference.
Map<String, dynamic> decodeAppPreferencesBackup(Object? value) {
  const invalid = FormatException('备份偏好格式或数值无效');
  if (value is! Map) throw invalid;
  final result = <String, dynamic>{};
  const booleans = {
    'useDynamicColor', 'playlistArtworkColorsEnabled', 'flowingLightEnabled',
    'lyricViewBlurDisabled', 'squareAlbumCoverEnabled', 'carPadModeEnabled',
    'skipStartupScreen', 'autoPlayOnStartup', 'showMiniLyrics',
    'allowMixWithOthers', 'bluetoothLyricEnabled', 'bluetoothFullLyricEnabled',
    'useBuiltInSourceFilePicker',
  };
  for (final key in booleans) {
    if (!value.containsKey(key)) continue;
    if (value[key] is! bool) throw invalid;
    result[key] = value[key];
  }
  final codes = <String, Set<String>>{
    'themeMode': {'system', 'light', 'dark'},
    'colorStyle': AppColorStyle.values.map((v) => v.code).toSet(),
    'navigationMode': AppNavigationMode.values.map((v) => v.code).toSet(),
    'onlinePlaybackQuality': OnlinePlaybackQuality.values.map((v) => v.code).toSet(),
    'batchDownloadQuality': OnlinePlaybackQuality.values.map((v) => v.code).toSet(),
  };
  for (final entry in codes.entries) {
    if (!value.containsKey(entry.key)) continue;
    final raw = value[entry.key];
    if (raw is! String || !entry.value.contains(raw)) throw invalid;
    result[entry.key] = raw;
  }
  if (value.containsKey('themeSeedArgb')) {
    final raw = value['themeSeedArgb'];
    if (raw is! int || raw < 0 || raw > 0xFFFFFFFF) throw invalid;
    result['themeSeedArgb'] = raw;
  }
  if (value.containsKey('crossfadeSeconds')) {
    final raw = value['crossfadeSeconds'];
    if (raw is! int || raw < 0 ||
        raw > kMaxCrossfadeMilliseconds ~/ Duration.millisecondsPerSecond) {
      throw invalid;
    }
    result['crossfadeMilliseconds'] = Duration(seconds: raw).inMilliseconds;
  }
  if (value.containsKey('crossfadeMilliseconds')) {
    final raw = value['crossfadeMilliseconds'];
    if (raw is! int || raw < 0 || raw > kMaxCrossfadeMilliseconds) throw invalid;
    result['crossfadeMilliseconds'] = raw;
  }
  final ranges = <String, (double, double)>{
    'lyricFontWeight': (kLyricFontWeightMin, kLyricFontWeightMax),
    'lyricTranslationFontWeight': (kLyricFontWeightMin, kLyricFontWeightMax),
    'lyricFontSize': (kLyricFontSizeMin, kLyricFontSizeMax),
    'lyricTranslationFontSize': (kLyricTranslationFontSizeMin, kLyricTranslationFontSizeMax),
  };
  for (final entry in ranges.entries) {
    if (!value.containsKey(entry.key)) continue;
    final raw = value[entry.key];
    if (!_inRange(raw, entry.value.$1, entry.value.$2)) throw invalid;
    result[entry.key] = raw;
  }
  if (value.containsKey('customTheme')) {
    // The existing complete theme schema treats absent color roles as reset.
    final raw = value['customTheme'];
    if (raw is! Map || raw['version'] is! int) throw invalid;
    for (final mode in ['light', 'dark']) {
      final colors = raw[mode];
      if (colors is! Map) throw invalid;
      for (final role in ThemeColorRole.values) {
        if (colors.containsKey(role.code) && colors[role.code] == null) throw invalid;
      }
    }
    result['customTheme'] = CustomTheme.fromJson(raw).toJson();
  }
  final sourceCodes = kManageableSearchSources.map((v) => v.code).toSet();
  for (final key in ['enabledSearchSources', 'discoverySourceOrder']) {
    if (!value.containsKey(key)) continue;
    final raw = value[key];
    if (raw is! List || raw.isEmpty ||
        raw.any((v) => v is! String || !sourceCodes.contains(v)) ||
        raw.toSet().length != raw.length ||
        (key == 'discoverySourceOrder' && raw.length != sourceCodes.length)) {
      throw invalid;
    }
    result[key] = List<String>.from(raw);
  }
  if (value.containsKey('equalizer')) {
    result['equalizer'] = _decodeEqualizer(value['equalizer']).toJson();
  }
  return result;
}

bool _inRange(Object? value, double min, double max) =>
    value is num && value.isFinite && value >= min && value <= max;

EqualizerSettings _decodeEqualizer(Object? value) {
  const invalid = FormatException('备份均衡器格式或数值无效');
  if (value is! Map || value['version'] is! int || value['version'] != 2 ||
      value['enabled'] is! bool ||
      !_inRange(value['inputGainDb'], equalizerMinGainDb, equalizerMaxGainDb) ||
      !_inRange(value['outputGainDb'], equalizerMinGainDb, equalizerMaxGainDb) ||
      !value.containsKey('presetId') ||
      (value['presetId'] != null && value['presetId'] is! String)) {
    throw invalid;
  }
  final bands = value['bands'];
  if (bands is! List || bands.length > equalizerMaxBands) throw invalid;
  final ids = <String>{};
  final types = EqualizerFilterType.values.map((v) => v.serializedName).toSet();
  final decoded = <Map<String, dynamic>>[];
  for (final band in bands) {
    if (band is! Map) throw invalid;
    final id = band['id'];
    if (id is! String || id.trim().isEmpty || !ids.add(id.trim()) ||
        band['enabled'] is! bool || !types.contains(band['type']) ||
        !_inRange(band['frequency'], equalizerMinFrequencyHz, equalizerMaxFrequencyHz) ||
        !_inRange(band['gain'], equalizerMinGainDb, equalizerMaxGainDb) ||
        !_inRange(band['q'], equalizerMinQ, equalizerMaxQ)) {
      throw invalid;
    }
    decoded.add({
      'id': id.trim(), 'enabled': band['enabled'], 'type': band['type'],
      'frequency': band['frequency'], 'gain': band['gain'], 'q': band['q'],
    });
  }
  // All model inputs are checked before using the compatibility parser.
  return EqualizerSettings.fromJson({
    'version': 2, 'enabled': value['enabled'],
    'inputGainDb': value['inputGainDb'], 'outputGainDb': value['outputGainDb'],
    'presetId': value['presetId'], 'bands': decoded,
  });
}
