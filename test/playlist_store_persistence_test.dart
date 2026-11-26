import 'dart:async';
import 'dart:convert';

import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/playlists/playlist_models.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/shared_preferences');
  late _PreferencesStorage storage;
  late SharedPreferences prefs;
  late ProviderContainer container;
  late LocalPlaylistNotifier store;

  setUp(() async {
    final date = DateTime.utc(2026);
    final original = LocalPlaylist(
      id: 'p',
      name: '原歌单',
      tracks: const [],
      createdAt: date,
      updatedAt: date,
    );
    storage = _PreferencesStorage(jsonEncode(original.toJson()));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, storage.handle);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    store = container.read(localPlaylistsProvider.notifier);
  });

  String cachedName() =>
      (jsonDecode(prefs.getStringList(localPlaylistsStorageKey)!.single)
              as Map)['name']
          as String;

  test(
    'failed save restores the provider and the optimistic preferences cache',
    () async {
      final result = expectLater(
        store.rename('p', '未保存'),
        throwsA(isA<PlaylistStoreException>()),
      );
      await storage.started.future;
      expect(store.byId('p')!.name, '未保存');
      expect(cachedName(), '未保存');
      storage.reply.complete(false);

      await result;
      expect(store.byId('p')!.name, '原歌单');
      expect(cachedName(), '原歌单');
    },
  );

  test('platform errors do not roll back a newer queued edit', () async {
    final first = expectLater(
      store.rename('p', '未保存'),
      throwsA(isA<PlaylistStoreException>()),
    );
    await storage.started.future;
    final second = store.rename('p', '较新编辑');
    expect(store.byId('p')!.name, '较新编辑');
    storage.reply.completeError(PlatformException(code: 'write-failed'));

    await first;
    expect(store.byId('p')!.name, '较新编辑');
    expect(await second, isTrue);
    expect(cachedName(), '较新编辑');
    await prefs.reload();
    expect(cachedName(), '较新编辑');
  });
}

class _PreferencesStorage {
  _PreferencesStorage(String row) : rows = [row];

  List<String> rows;
  final started = Completer<void>();
  final reply = Completer<bool>();

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'getAll':
        return {'flutter.$localPlaylistsStorageKey': rows};
      case 'setStringList':
        if (!started.isCompleted) {
          started.complete();
          if (!await reply.future) return false;
        }
        rows = List<String>.from(call.arguments['value'] as List);
        return true;
      default:
        throw MissingPluginException(call.method);
    }
  }
}
