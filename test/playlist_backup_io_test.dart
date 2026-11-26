import 'dart:convert';

import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/core/sync/playlist_backup_service.dart';
import 'package:cy_shine_music/core/sync/webdav_client.dart';
import 'package:cy_shine_music/core/sync/webdav_config_store.dart';
import 'package:cy_shine_music/core/sync/webdav_sync_controller.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('local file picker/saver work without any WebDAV configuration and cancellation does not write', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    String? saved;
    String? picked;
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      playlistBackupFileSaverProvider.overrideWithValue((name, text) async {
        expect(name, endsWith('.json'));
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
    expect(jsonDecode(remote[name]!)['format'], 'cyshine-playlist-backup');
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
}

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
  _CloudClient(WebDavSyncConfig config, this.files) : super(config, dio: Dio());
  final Map<String, String> files;
  @override
  Future<void> uploadPlaylistBackup(String name, String text) async { files[name] = text; }
  @override
  Future<List<String>> listPlaylistBackups() async => files.keys.toList();
  @override
  Future<String> readPlaylistBackup(String name) async => files[name]!;
}
