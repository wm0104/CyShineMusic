import 'dart:convert';
import 'dart:io';

import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/music_sources/music_source_controller.dart';
import 'package:cy_shine_music/core/music_sources/music_source_models.dart';
import 'package:cy_shine_music/core/music_sources/music_source_runtime.dart';
import 'package:cy_shine_music/core/music_sources/music_source_store.dart';

import 'package:cy_shine_music/core/storage/app_preferences_backup.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/core/sync/playlist_backup_service.dart';
import 'package:cy_shine_music/core/sync/webdav_client.dart';
import 'package:cy_shine_music/core/sync/webdav_config_store.dart';
import 'package:cy_shine_music/core/sync/webdav_sync_controller.dart';
import 'package:cy_shine_music/features/equalizer/equalizer_store.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late ProviderContainer container;
  late _SourceRuntime runtime;
  String? picked;
  String? saved;
  final cloud = <String, String>{};

  ProviderContainer open() => ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    musicSourceRuntimeProvider.overrideWithValue(runtime),
    playlistBackupFilePickerProvider.overrideWithValue(() async => picked),
    playlistBackupFileSaverProvider.overrideWithValue((name, text) async {
      saved = text;
      return true;
    }),
    webDavConfigStoreProvider.overrideWithValue(_ConfigStore(prefs)),
    webDavClientFactoryProvider.overrideWithValue((config) => _Cloud(config, cloud)),
  ]);

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'download_dir': '/device/downloads',
      'local_music_dir': '/device/music',
      'car_display_enabled': true,
      'car_display_size': 1.1,
      'sentinel_credential': 'test-only-secret',
    });
    prefs = await SharedPreferences.getInstance();
    runtime = _SourceRuntime();
    picked = null;
    saved = null;
    cloud.clear();
    container = open();
  });
  tearDown(() => container.dispose());

  Future<void> mockSourceFiles() async {
    final root = await Directory.systemTemp.createTemp('cyshine-manual-backup-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => root.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    });
  }

  for (final remote in [false, true]) {
    test('${remote ? 'cloud' : 'local'} manual backup restores scripts, capabilities and enabled order', () async {
      await mockSourceFiles();
      final sources = container.read(musicSourceControllerProvider.notifier);
      const firstScript = '// @name One\n// @author Test';
      const dormantScript = '// @name Dormant\n// @author Test';
      const lastScript = '// @name Last\n// @author Test';
      const newerScript = '// @name One\n// @author Test\n// @version 2';
      final first = await sources.importScript(script: firstScript, origin: '/device/source.js');
      final dormant = await sources.importScript(script: dormantScript, origin: 'test');
      await sources.deactivate(dormant.id);
      final last = await sources.importScript(script: lastScript, origin: 'test');
      final service = container.read(playlistBackupServiceProvider);
      if (remote) {
        await service.uploadCloud();
        saved = cloud.values.single;
      } else {
        await service.exportLocal();
        picked = saved;
      }
      final section = (jsonDecode(saved!) as Map)['musicSources'] as Map;
      expect((section['scripts'] as Map).length, 3);
      expect(saved, isNot(contains('/device/source.js')));
      expect(section['enabledIds'], [first.id, last.id]);

      for (final record in [first, dormant, last]) {
        await sources.remove(record.id);
      }
      final local = await sources.importScript(script: '// @name Local', origin: 'local');
      runtime.failOn = dormant.id; // A disabled or offline script need not initialize.
      Future<int?> restore() => remote ? service.restoreCloud(cloud.keys.single) : service.importLocal();
      expect(await restore(), 3);
      expect(container.read(musicSourceControllerProvider).requireValue.enabledIds, [local.id, first.id, last.id]);
      await sources.importScript(script: newerScript, origin: 'local');
      await sources.deactivate(first.id);
      expect(await restore(), 0);
      container.dispose();
      await prefs.reload();
      container = open();
      final recovered = await container.read(musicSourceControllerProvider.future);
      expect(recovered.records.map((row) => row.id), [local.id, first.id, dormant.id, last.id]);
      expect(recovered.enabledIds, [local.id, last.id]);
      expect(recovered.records.last.supports(MusicSource.kw), isTrue);
      final store = container.read(musicSourceStoreProvider);
      expect(await store.readScript(first.id), newerScript);
      expect(await store.readScript(dormant.id), dormantScript);
      expect(await store.readScript(last.id), lastScript);
    });

    test('${remote ? 'cloud' : 'local'} backup restores preferences and equalizer durably', () async {
      final settings = container.read(settingsProvider.notifier);
      await settings.setThemeMode(ThemeMode.dark);
      await settings.setNavigationMode(AppNavigationMode.dualCapsule);
      await settings.setAutoPlayOnStartup(true);
      await settings.setCrossfadeMilliseconds(6);
      container.read(equalizerProvider.notifier).setEnabled(true);
      await container.read(localPlaylistsProvider.notifier).create('portable');
      final service = container.read(playlistBackupServiceProvider);
      if (remote) {
        await service.uploadCloud();
        saved = cloud.values.single;
      } else {
        expect(await service.exportLocal(), isTrue);
      }
      final document = jsonDecode(saved!) as Map<String, dynamic>;
      expect(document['version'], 1);
      final preferences = document['preferences'] as Map;
      expect(preferences.length, 28);
      expect(preferences['crossfadeMilliseconds'], 6);
      expect(preferences['themeMode'], 'dark');
      expect((preferences['equalizer'] as Map)['enabled'], isTrue);
      expect(saved, isNot(contains('test-only-secret')));
      expect(saved, isNot(contains('/device/')));
      for (final excluded in ['downloadDir', 'localMusicDir', 'carDisplayEnabled',
        'carDisplaySize', 'networkAdapterMode', 'debugMode', 'bluetoothLyricNoticeSeen']) {
        expect(preferences.containsKey(excluded), isFalse);
      }
      await settings.setThemeMode(ThemeMode.light);
      await settings.setNavigationMode(AppNavigationMode.native);
      await settings.setAutoPlayOnStartup(false);
      await settings.setCrossfadeMilliseconds(0);
      container.read(equalizerProvider.notifier).setEnabled(false);
      if (remote) {
        await service.restoreCloud(cloud.keys.single);
      } else {
        picked = saved;
        await service.importLocal();
      }
      container.dispose();
      await prefs.reload();
      container = open();
      final restored = container.read(settingsProvider);
      expect(restored.themeMode, ThemeMode.dark);
      expect(restored.navigationMode, AppNavigationMode.dualCapsule);
      expect(restored.autoPlayOnStartup, isTrue);
      expect(restored.crossfadeMilliseconds, 6);
      expect(container.read(equalizerProvider).enabled, isTrue);
      expect(prefs.getString('sentinel_credential'), 'test-only-secret');
      expect(restored.downloadDir, '/device/downloads');
      expect(restored.carDisplayEnabled, isTrue);
    });
  }

  test('a bad source or failed initialization cannot partially import a playlist or preferences', () async {
    await mockSourceFiles();
    final sources = container.read(musicSourceControllerProvider.notifier);
    final record = await sources.importScript(script: '// @name Fixture', origin: 'test');
    final playlists = container.read(localPlaylistsProvider.notifier);
    final service = container.read(playlistBackupServiceProvider);
    final playlist = await playlists.create('inside backup');
    await container.read(settingsProvider.notifier).setThemeMode(ThemeMode.dark);
    await service.exportLocal();
    await playlists.delete(playlist.id);
    await sources.remove(record.id);
    await container.read(settingsProvider.notifier).setThemeMode(ThemeMode.light);
    for (final damageScript in [true, false]) {
      final file = jsonDecode(saved!) as Map;
      if (damageScript) {
        file['musicSources']['scripts'][record.id] = '// @name Different';
      } else {
        runtime.failOn = record.id;
      }
      picked = jsonEncode(file);
      await expectLater(service.importLocal(), throwsA(isA<MusicSourceRuntimeException>()));
      expect(container.read(musicSourceControllerProvider).requireValue.records, isEmpty);
      expect(container.read(settingsProvider).themeMode, ThemeMode.light);
      expect(container.read(localPlaylistsProvider), isEmpty);
    }
  });

  test('legacy whole seconds migrate and a saved zero takes precedence on restart', () async {
    await prefs.setInt('crossfade_seconds', 4);
    final settings = container.read(settingsProvider.notifier);
    expect(container.read(settingsProvider).crossfadeMilliseconds, 4000);
    expect(settings.exportPreferencesForBackup()['crossfadeMilliseconds'], 4000);

    await settings.setCrossfadeMilliseconds(0);
    container.dispose();
    await prefs.reload();
    container = open();
    expect(container.read(settingsProvider).crossfadeMilliseconds, 0);
  });

  test('restores legacy crossfade seconds, preferring an exact value when both are present', () async {
    final document = jsonDecode(container.read(localPlaylistsProvider.notifier).exportBackup()) as Map;
    final service = container.read(playlistBackupServiceProvider);
    picked = jsonEncode({...document, 'preferences': {'crossfadeSeconds': 12}});
    await service.importLocal();
    expect(container.read(settingsProvider).crossfadeMilliseconds, 12000);

    picked = jsonEncode({...document, 'preferences': {
      'crossfadeMilliseconds': 2360, 'crossfadeSeconds': 2,
    }});
    await service.importLocal();
    expect(container.read(settingsProvider).crossfadeMilliseconds, 2360);
  });

  test('legacy backup and picker cancellation do not touch preferences', () async {
    final settings = container.read(settingsProvider.notifier);
    await settings.setThemeMode(ThemeMode.dark);
    await mockSourceFiles();
    final record = await container.read(musicSourceControllerProvider.notifier)
        .importScript(script: '// @name Keep', origin: '/device/example.js');
    final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
    expect(await container.read(playlistBackupServiceProvider).importLocal(), isNull);
    expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, before);
    picked = container.read(localPlaylistsProvider.notifier).exportBackup();
    await container.read(playlistBackupServiceProvider).importLocal();
    final old = jsonDecode(picked!) as Map;
    picked = jsonEncode({...old, 'musicSources': {'records': [], 'enabledIds': [], 'scripts': {}}});
    await container.read(playlistBackupServiceProvider).importLocal();
    expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, before);
    expect(container.read(musicSourceControllerProvider).requireValue.enabledIds, [record.id]);
  });

  test('partial restore preserves dynamic artwork and translation after restart', () async {
    final settings = container.read(settingsProvider.notifier);
    await settings.setPlaylistArtworkColorsEnabled(true);
    await settings.setCrossfadeMilliseconds(2360);
    // No stored translation style: preserve the current derived values too.
    final original = container.read(settingsProvider);
    picked = jsonEncode({
      ...jsonDecode(container.read(localPlaylistsProvider.notifier).exportBackup()) as Map,
      'preferences': {
        'customTheme': {'version': 1, 'enabled': true, 'light': {}, 'dark': {}},
        'lyricFontSize': 48,
        'lyricFontWeight': 800,
        'downloadDir': '/untrusted', 'carDisplayEnabled': false,
        'sentinel_credential': 'overwrite',
      },
    });
    await container.read(playlistBackupServiceProvider).importLocal();
    container.dispose();
    await prefs.reload();
    container = open();
    final restored = container.read(settingsProvider);
    expect(restored.customTheme.enabled, isTrue);
    expect(restored.playlistArtworkColorsEnabled, isTrue);
    expect(restored.crossfadeMilliseconds, 2360);
    expect(restored.lyricFontSize, 48);
    expect(restored.lyricFontWeight, 800);
    expect(restored.lyricTranslationFontSize, original.lyricTranslationFontSize);
    expect(restored.lyricTranslationFontWeight, original.lyricTranslationFontWeight);
    expect(restored.downloadDir, original.downloadDir);
    expect(restored.carDisplayEnabled, isTrue);
    expect(prefs.getString('sentinel_credential'), 'test-only-secret');
  });

  test('bad preferences reject the entire valid playlist document before writes', () async {
    final store = container.read(localPlaylistsProvider.notifier);
    final playlist = await store.create('incoming');
    final document = jsonDecode(store.exportBackup()) as Map<String, dynamic>;
    await store.delete(playlist.id);
    final invalid = <Object?>[
      null,
      {'themeMode': null},
      {'themeMode': 'unknown'},
      {'autoPlayOnStartup': 1},
      {'themeSeedArgb': -1},
      {'lyricFontSize': 57},
      {'crossfadeSeconds': -1}, {'crossfadeSeconds': 13}, {'crossfadeSeconds': 1.5},
      {'crossfadeMilliseconds': -1}, {'crossfadeMilliseconds': 12001},
      {'crossfadeMilliseconds': 0.5},
      {'onlinePlaybackQuality': 'master'},
      {'enabledSearchSources': ['wy', 'wy']},
      {'enabledSearchSources': []},
      {'discoverySourceOrder': ['wy']},
      {'equalizer': {'version': 2, 'enabled': true, 'inputGainDb': 25,
        'outputGainDb': 0, 'presetId': null, 'bands': []}},
    ];
    for (final preferences in invalid) {
      final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
      picked = jsonEncode({...document, 'preferences': preferences});
      await expectLater(container.read(playlistBackupServiceProvider).importLocal(), throwsFormatException);
      expect(container.read(localPlaylistsProvider), isEmpty);
      expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, before);
    }
  });

  test('all whitelist fields survive restore and provider reconstruction', () async {
    final expected = <String, dynamic>{
      'themeMode': 'dark', 'themeSeedArgb': 0xFF123456, 'colorStyle': 'vivid',
      'useDynamicColor': true,
      'customTheme': {'version': 1, 'enabled': true,
        'light': {'accent': 0xFFABCDEF}, 'dark': {'text': 0xFFFEDCBA}},
      'playlistArtworkColorsEnabled': true, 'flowingLightEnabled': false,
      'lyricViewBlurDisabled': true, 'squareAlbumCoverEnabled': true,
      'lyricFontWeight': 800.0, 'lyricTranslationFontWeight': 600.0,
      'lyricFontSize': 45.0, 'lyricTranslationFontSize': 22.0,
      'navigationMode': 'dual_capsule', 'carPadModeEnabled': true,
      'skipStartupScreen': true, 'autoPlayOnStartup': true,
      'showMiniLyrics': false, 'allowMixWithOthers': true, 'crossfadeMilliseconds': 12000,
      'bluetoothLyricEnabled': true, 'bluetoothFullLyricEnabled': true,
      'onlinePlaybackQuality': 'flac', 'batchDownloadQuality': '320k',
      'enabledSearchSources': ['kw', 'mg'],
      'discoverySourceOrder': ['mg', 'kg', 'kw', 'tx', 'wy'],
      'useBuiltInSourceFilePicker': true,
    };
    final equalizer = {'version': 2, 'enabled': true, 'inputGainDb': 3.0,
      'outputGainDb': -4.0, 'presetId': 'custom.portable', 'bands': [
        {'id': 'band-1', 'enabled': true, 'type': 'HighShelf',
          'frequency': 8000.0, 'gain': -2.0, 'q': 0.8},
      ]};
    picked = jsonEncode({
      ...jsonDecode(container.read(localPlaylistsProvider.notifier).exportBackup()) as Map,
      'preferences': {...expected, 'equalizer': equalizer},
    });
    await container.read(playlistBackupServiceProvider).importLocal();
    container.dispose();
    await prefs.reload();
    container = open();
    expect(container.read(settingsProvider.notifier).exportPreferencesForBackup(), expected);
    expect(container.read(equalizerProvider).toJson(), equalizer);
    expect(container.read(settingsProvider).bluetoothLyricNoticeSeen, isFalse);
  });

  test('strict boundary rejects nulls, nonfinite numbers and invalid equalizer bands', () {
    final base = container.read(settingsProvider.notifier).exportPreferencesForBackup();
    for (final key in base.keys) {
      expect(() => decodeAppPreferencesBackup({key: null}), throwsFormatException,
        reason: key);
    }
    for (final value in [double.nan, double.infinity, double.negativeInfinity]) {
      expect(() => decodeAppPreferencesBackup({'lyricFontSize': value}), throwsFormatException);
    }
    final band = {'id': 'one', 'enabled': true, 'type': 'Peaking',
      'frequency': 1000, 'gain': 0, 'q': 0.707};
    final eq = {'version': 2, 'enabled': true, 'inputGainDb': 0,
      'outputGainDb': 0, 'presetId': null, 'bands': [band]};
    final invalidBands = [
      [{...band, 'frequency': 19}], [{...band, 'q': 11}],
      [{...band, 'gain': double.nan}], [{...band, 'type': 'unknown'}],
      [{...band, 'enabled': null}], [{...band, 'id': ''}],
      [band, band], List.generate(33, (i) => {...band, 'id': '$i'}),
    ];
    for (final bands in invalidBands) {
      expect(() => decodeAppPreferencesBackup({'equalizer': {...eq, 'bands': bands}}), throwsFormatException);
    }
    expect(() => decodeAppPreferencesBackup({'equalizer': {...eq, 'version': 1}}), throwsFormatException);
    expect(decodeAppPreferencesBackup({'futureKey': true}), isEmpty);
  });

  test('playlist identity conflict cannot change preferences', () async {
    final store = container.read(localPlaylistsProvider.notifier);
    await store.create('local');
    final document = jsonDecode(store.exportBackup()) as Map<String, dynamic>;
    final row = (document['playlists'] as List).single as Map<String, dynamic>;
    row['originPlaylistId'] = 'different-origin';
    row['originSource'] = 'wy';
    document['preferences'] = {'themeMode': 'dark'};
    final original = container.read(settingsProvider).themeMode;
    final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
    picked = jsonEncode(document);
    await expectLater(container.read(playlistBackupServiceProvider).importLocal(), throwsFormatException);
    expect(container.read(settingsProvider).themeMode, original);
    expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, before);
  });

  test('bad playlist cannot apply valid preferences', () async {
    container.read(settingsProvider);
    final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
    picked = jsonEncode({'format': 'cyshine-playlist-backup', 'version': 1,
      'playlists': [null], 'preferences': {'themeMode': 'dark'}});
    await expectLater(container.read(playlistBackupServiceProvider).importLocal(), throwsFormatException);
    expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, before);
  });
}

class _ConfigStore extends WebDavConfigStore {
  _ConfigStore(SharedPreferences prefs) : super(prefs, _NoSecrets());
  @override
  Future<WebDavSyncConfig> load() async => const WebDavSyncConfig(
    baseUrl: 'https://dav.invalid', username: '', password: '', linked: true,
  );
}

class _NoSecrets implements WebDavSecretStore {
  @override
  Future<String?> read(String key) async => throw StateError('no credential reads');
  @override
  Future<void> write(String key, String value) async => throw StateError('no credential writes');
  @override
  Future<void> delete(String key) async => throw StateError('no credential deletes');
}

class _Cloud extends WebDavClient {
  _Cloud(WebDavSyncConfig config, this.files) : super(config, dio: Dio());
  final Map<String, String> files;
  @override
  Future<void> uploadPlaylistBackup(String name, String text) async { files[name] = text; }
  @override
  Future<List<String>> listPlaylistBackups() async => files.keys.toList();
  @override
  Future<String> readPlaylistBackup(String name) async => files[name]!;
}

class _SourceRuntime extends MusicSourceRuntime {
  _SourceRuntime() : super(Dio(), channel: const MethodChannel('mock/backup-source'));
  String? failOn;
  @override
  Future<Map<MusicSource, List<Quality>>> load(MusicSourceRecord record, String script) async {
    if (record.id == failOn) throw const MusicSourceRuntimeException('fixture unavailable');
    return const {MusicSource.kw: [Quality.k128]};
  }
  @override
  Future<void> disposeRuntime() async {}
}
