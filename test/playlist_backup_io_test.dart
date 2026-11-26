import 'dart:convert';

import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/core/sync/playlist_backup_service.dart';
import 'package:cy_shine_music/core/sync/webdav_client.dart';
import 'package:cy_shine_music/core/sync/webdav_config_store.dart';
import 'package:cy_shine_music/core/sync/webdav_sync_controller.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final saved in [true, false, null]) {
    test('iOS backup export delegates date-only name and cancellation result $saved to native picker', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      const channel = MethodChannel('cy_shine_music/audio_intent');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return saved;
      });
      final container = ProviderContainer();
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(channel, null);
        container.dispose();
      });
      const name = '栖弦备份-2026-11-26.json';
      const text = '{"playlists":[]}';
      expect(await container.read(playlistBackupFileSaverProvider)(name, text), saved == true);
      expect(calls.single.method, 'savePlaylistBackup');
      expect(calls.single.arguments, {'name': name, 'text': text});
    });
  }

  test('iOS backup export surfaces native export failures without falling back to file_picker', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel('cy_shine_music/audio_intent');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'WRITE_FAILED');
    });
    final container = ProviderContainer();
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
      container.dispose();
    });
    await expectLater(
      container.read(playlistBackupFileSaverProvider)('栖弦备份-2026-11-26.json', '{}'),
      throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'WRITE_FAILED')),
    );
  });

  test('local file picker/saver work without any WebDAV configuration and cancellation does not write', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    String? saved;
    String? picked;
    final before = _dateName(DateTime.now());
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      playlistBackupFileSaverProvider.overrideWithValue((name, text) async {
        expect(name, isIn([before, _dateName(DateTime.now())]));
        saved = text;
        return true;
      }),
      playlistBackupFilePickerProvider.overrideWithValue(() async => picked),
    ]);
    addTearDown(container.dispose);
    final store = container.read(localPlaylistsProvider.notifier);
    final playlist = await store.create('local');
    final service = container.read(playlistBackupServiceProvider);
    expect(await service.exportLocal(), isTrue);
    expect(jsonDecode(saved!)['playlists'], hasLength(1));
    await store.delete(playlist.id);
    expect(await service.importLocal(), isNull);
    expect(container.read(localPlaylistsProvider), isEmpty);
    picked = saved;
    expect(await service.importLocal(), 1);
    expect(await service.importLocal(), 0);
    picked = '{broken';
    await expectLater(service.importLocal(), throwsFormatException);
    expect(container.read(localPlaylistsProvider).single.id, playlist.id);
  });

  test('cloud service uses the configured factory and corrupt restore cannot change local data', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final remote = <String, String>{};
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      webDavConfigStoreProvider.overrideWithValue(_ConfigStore(prefs)),
      webDavClientFactoryProvider.overrideWithValue((config) => _CloudClient(config, remote)),
    ]);
    addTearDown(container.dispose);
    final store = container.read(localPlaylistsProvider.notifier);
    final playlist = await store.create('cloud copy');
    final service = container.read(playlistBackupServiceProvider);
    await service.uploadCloud();
    final name = (await service.listCloud()).single;
    expect(name, matches(r'^栖弦备份-\d{4}-\d{2}-\d{2}\.json$'));
    expect(jsonDecode(remote[name]!)['format'], 'cyshine-playlist-backup');
    final original = remote[name];
    await service.uploadCloud();
    expect(remote.keys, containsAll([name, name.replaceFirst('.json', '-2.json')]));
    expect(remote[name], original);
    await store.delete(playlist.id);
    expect(await service.restoreCloud(name), 1);
    expect(await service.restoreCloud(name), 0);
    final before = store.exportBackup();
    final stored = prefs.getStringList(localPlaylistsStorageKey);
    remote[name] = '{corrupt';
    await expectLater(service.restoreCloud(name), throwsFormatException);
    expect(store.exportBackup(), before);
    expect(prefs.getStringList(localPlaylistsStorageKey), stored);
  });

  test('cloud backup retries racing create-only conflicts with numeric suffixes', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final remote = <String, String>{};
    final attempts = <String>[];
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      webDavConfigStoreProvider.overrideWithValue(_ConfigStore(prefs)),
      webDavClientFactoryProvider.overrideWithValue((config) => _CloudClient(config, remote,
        beforeUpload: (name) {
          attempts.add(name);
          if (attempts.length <= 2) remote[name] = 'another device';
        },
      )),
    ]);
    addTearDown(container.dispose);
    await container.read(playlistBackupServiceProvider).uploadCloud();
    final base = attempts.first.replaceFirst('.json', '');
    expect(attempts, ['$base.json', '$base-2.json', '$base-3.json']);
    expect(remote['$base.json'], 'another device');
    expect(remote['$base-2.json'], 'another device');
    expect(jsonDecode(remote['$base-3.json']!)['format'], 'cyshine-playlist-backup');
  });

  test('cloud backup bounds conflict retries and does not retry permission errors', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    for (final status in [412, 403]) {
      var attempts = 0;
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        webDavConfigStoreProvider.overrideWithValue(_ConfigStore(prefs)),
        webDavClientFactoryProvider.overrideWithValue((config) => _CloudClient(config, {},
          beforeUpload: (_) {
            attempts++;
            throw WebDavException('test failure', statusCode: status);
          },
        )),
      ]);
      try {
        await expectLater(container.read(playlistBackupServiceProvider).uploadCloud(), throwsA(isA<WebDavException>()));
        expect(attempts, status == 412 ? 10 : 1);
      } finally {
        container.dispose();
      }
    }
  });

  test('cloud upload tolerates unavailable directory listing but still rejects invalid authentication', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    for (final status in [403, 405, 409, 501, 401]) {
      final remote = <String, String>{};
      var attempts = 0;
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        webDavConfigStoreProvider.overrideWithValue(_ConfigStore(prefs)),
        webDavClientFactoryProvider.overrideWithValue((config) => _CloudClient(config, remote,
          listStatus: status,
          beforeUpload: (name) {
            attempts++;
            if (attempts == 1) remote[name] = 'existing backup';
          },
        )),
      ]);
      try {
        final uploading = container.read(playlistBackupServiceProvider).uploadCloud();
        if (status == 401) {
          await expectLater(uploading, throwsA(isA<WebDavException>().having((error) => error.statusCode, 'statusCode', 401)));
          expect(attempts, 0);
        } else {
          await uploading;
          expect(attempts, 2);
          expect(remote.length, 2);
          expect(remote.values, contains('existing backup'));
        }
      } finally {
        container.dispose();
      }
    }
  });

  test('manual WebDAV backup never touches sync-v1 and filters list to own backup directory', () async {
    final requests = <RequestOptions>[];
    final manifest = jsonEncode({'format': 'cyshine-playlist-backup', 'version': 1, 'playlists': []});
    final dio = Dio(BaseOptions(responseType: ResponseType.plain, validateStatus: (code) => code != null && code < 600));
    dio.httpClientAdapter = _Adapter((options) {
      requests.add(options);
      if (options.method == 'PROPFIND') return ResponseBody.fromString('''
<d:multistatus xmlns:d="DAV:">
<d:response><d:href>/dav/CyShineMusic/playlist-backups/playlist-backup-v1-2.json</d:href></d:response>
<d:response><d:href>playlist-backup-v1-1.json</d:href></d:response>
<d:response><d:href>/dav/CyShineMusic/sync-v1.json</d:href></d:response>
<d:response><d:href>https://other.invalid/dav/CyShineMusic/playlist-backups/playlist-backup-v1-3.json</d:href></d:response>
<d:response><d:href>/else/playlist-backup-v1-4.json</d:href></d:response>
</d:multistatus>''', 207);
      if (options.method == 'GET') return ResponseBody.fromString(manifest, 200);
      return ResponseBody.fromString('', options.method == 'MKCOL' ? 405 : 201);
    });
    final client = WebDavClient(const WebDavSyncConfig(baseUrl: 'https://dav.invalid/dav', username: '', password: ''), dio: dio);
    addTearDown(client.close);
    await client.uploadPlaylistBackup('playlist-backup-v1-2.json', manifest);
    expect(await client.listPlaylistBackups(), ['playlist-backup-v1-2.json', 'playlist-backup-v1-1.json']);
    expect(await client.readPlaylistBackup('playlist-backup-v1-2.json'), manifest);
    expect(requests.map((r) => r.method), ['MKCOL', 'MKCOL', 'PUT', 'PROPFIND', 'GET']);
    expect(requests.any((r) => r.uri.path.endsWith('/sync-v1.json')), isFalse);
    expect(requests[2].headers['If-None-Match'], '*');
    await expectLater(client.readPlaylistBackup('../sync-v1.json'), throwsFormatException);
  });

  test('Chinese cloud names round-trip and mixed backup formats sort newest first', () async {
    final requests = <RequestOptions>[];
    final legacy = 'playlist-backup-v1-${DateTime.utc(2026, 11, 26, 9).microsecondsSinceEpoch}.json';
    const latest = '栖弦备份-2026-11-26-2.json';
    const first = '栖弦备份-2026-11-26.json';
    final dio = Dio(BaseOptions(responseType: ResponseType.plain, validateStatus: (code) => code != null && code < 600));
    dio.httpClientAdapter = _Adapter((options) {
      requests.add(options);
      if (options.method == 'PROPFIND') {
        return ResponseBody.fromString('''
<d:multistatus xmlns:d="DAV:">
<d:response><d:href>${Uri.encodeComponent(first)}</d:href><d:propstat><d:prop><d:getlastmodified>Thu, 26 Nov 2026 08:00:00 GMT</d:getlastmodified></d:prop></d:propstat></d:response>
<d:response><d:href>$legacy</d:href><d:propstat><d:prop><d:getlastmodified>Thu, 26 Nov 2026 09:00:00 GMT</d:getlastmodified></d:prop></d:propstat></d:response>
<d:response><d:href>${Uri.encodeComponent(latest)}</d:href><d:propstat><d:prop><d:getlastmodified>Thu, 26 Nov 2026 10:00:00 GMT</d:getlastmodified></d:prop></d:propstat></d:response>
<d:response><d:href>栖弦备份-2026-02-30.json</d:href></d:response>
<d:response><d:href>栖弦备份-2026-11-26-0.json</d:href></d:response>
</d:multistatus>''', 207);
      }
      if (options.method == 'GET') return ResponseBody.fromString('backup', 200);
      return ResponseBody.fromString('', options.method == 'MKCOL' ? 405 : 201);
    });
    final client = WebDavClient(const WebDavSyncConfig(baseUrl: 'https://dav.invalid/dav', username: '', password: ''), dio: dio);
    addTearDown(client.close);
    await client.uploadPlaylistBackup(latest, 'backup');
    expect(await client.listPlaylistBackups(), [latest, legacy, first]);
    expect(await client.readPlaylistBackup(latest), 'backup');
    expect(await client.readPlaylistBackup(legacy), 'backup');
    expect(requests.where((request) => request.method == 'PUT').single.headers['If-None-Match'], '*');
    expect(requests.where((request) => request.method == 'PUT').single.uri.pathSegments.last, latest);
    expect(requests.where((request) => request.method == 'PROPFIND').single.data, contains('<d:getlastmodified/>'));
    await expectLater(client.readPlaylistBackup('栖弦备份-2026-02-30.json'), throwsFormatException);
  });

  test('cloud list falls back to filename dates and numeric suffixes without valid modification dates', () async {
    final legacy = 'playlist-backup-v1-${DateTime(2026, 11, 25, 23).microsecondsSinceEpoch}.json';
    final dio = Dio(BaseOptions(responseType: ResponseType.plain));
    dio.httpClientAdapter = _Adapter((_) => ResponseBody.fromString('''
<multistatus xmlns="DAV:">
<response><href>栖弦备份-2026-11-26-2.json</href><getlastmodified>invalid</getlastmodified></response>
<response><href>栖弦备份-2026-11-24.json</href></response>
<response><href>$legacy</href></response>
<response><href>栖弦备份-2026-11-26.json</href></response>
<response><href>栖弦备份-2026-11-26-10.json</href></response>
</multistatus>''', 207));
    final client = WebDavClient(const WebDavSyncConfig(baseUrl: 'https://dav.invalid/dav', username: '', password: ''), dio: dio);
    addTearDown(client.close);
    expect(await client.listPlaylistBackups(), [
      '栖弦备份-2026-11-26-10.json', '栖弦备份-2026-11-26-2.json',
      '栖弦备份-2026-11-26.json', legacy, '栖弦备份-2026-11-24.json',
    ]);
  });
}

String _dateName(DateTime date) => '栖弦备份-${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}.json';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final ResponseBody Function(RequestOptions) handler;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream, Future<void>? cancelFuture) async => handler(options);
  @override
  void close({bool force = false}) {}
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
  Future<String?> read(String key) async => throw StateError('test must not read credentials');
  @override
  Future<void> write(String key, String value) async => throw StateError('test must not write credentials');
  @override
  Future<void> delete(String key) async => throw StateError('test must not delete credentials');
}

class _CloudClient extends WebDavClient {
  _CloudClient(super.config, this.files, {this.beforeUpload, this.listStatus}) : super(dio: Dio());
  final Map<String, String> files;
  final void Function(String name)? beforeUpload;
  final int? listStatus;
  @override
  Future<void> uploadPlaylistBackup(String name, String text) async {
    beforeUpload?.call(name);
    if (files.containsKey(name)) throw const WebDavException('already exists', statusCode: 412);
    files[name] = text;
  }
  @override
  Future<List<String>> listPlaylistBackups() async {
    if (listStatus != null) throw WebDavException('cannot list', statusCode: listStatus);
    return files.keys.toList();
  }
  @override
  Future<String> readPlaylistBackup(String name) async => files[name]!;
}
