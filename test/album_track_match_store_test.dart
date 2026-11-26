import 'dart:convert';

import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/discovery/album_track_match_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

MusicInfo song(String id, MusicSource source) => MusicInfo.fromJson({
  'id': '${source.code}_$id', 'name': id, 'singer': 'Artist', 'source': source.code,
  'meta': {'songId': id, 'albumName': 'Album', 'qualitys': []},
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('manual album matches survive restart and stay scoped to original identity', () async {
    final prefs = await SharedPreferences.getInstance();
    ProviderContainer open() => ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    var container = open();
    final original = song('original', MusicSource.wy);
    final chosen = song('chosen', MusicSource.tx);
    final key = albumTrackMatchKey(source: MusicSource.wy, albumId: 'a', original: original);
    expect(await container.read(albumTrackMatchesProvider.notifier).setMatch(source: MusicSource.wy, albumId: 'a', original: original, replacement: chosen, expected: null), isTrue);
    expect(container.read(albumTrackMatchesProvider)[key]?.source, MusicSource.tx);
    expect(container.read(albumTrackMatchesProvider).containsKey(albumTrackMatchKey(source: MusicSource.wy, albumId: 'b', original: original)), isFalse);
    expect(container.read(albumTrackMatchesProvider).containsKey(albumTrackMatchKey(source: MusicSource.tx, albumId: 'a', original: song('original', MusicSource.tx))), isFalse);
    expect(original.source, MusicSource.wy);
    container.dispose();
    container = open();
    expect(container.read(albumTrackMatchesProvider)[key]?.id, chosen.id);
    container.dispose();
  });

  test('older picker result cannot overwrite a newer selection or cleared expectation', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    final store = container.read(albumTrackMatchesProvider.notifier);
    final original = song('o', MusicSource.wy);
    final first = song('1', MusicSource.tx);
    final second = song('2', MusicSource.kw);
    Future<bool> save(MusicInfo value, MusicInfo? expected) => store.setMatch(source: MusicSource.wy, albumId: 'a', original: original, replacement: value, expected: expected);
    expect(await save(first, null), isTrue);
    expect(await save(second, first), isTrue);
    expect(await save(first, null), isFalse);
    expect(await save(first, first), isFalse);
    expect(container.read(albumTrackMatchesProvider).values.single.id, second.id);
    // Cancellation does not call setMatch and must leave the record intact.
    expect(container.read(albumTrackMatchesProvider).length, 1);
  });

  test('simultaneous stale saves cannot both persist across reload', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    final store = container.read(albumTrackMatchesProvider.notifier);
    final original = song('o', MusicSource.wy);
    Future<bool> save(String id) => store.setMatch(source: MusicSource.wy, albumId: 'a', original: original, replacement: song(id, MusicSource.tx), expected: null);
    expect(await Future.wait([save('first'), save('stale')]), [true, false]);
    container.dispose();
    final restored = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(restored.dispose);
    expect(restored.read(albumTrackMatchesProvider).values.single.id, 'tx_first');
  });

  test('malformed stored rows do not discard other persisted manual choices', () async {
    final original = song('o', MusicSource.wy);
    final replacement = song('r', MusicSource.tx);
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    await c.read(albumTrackMatchesProvider.notifier).setMatch(source: MusicSource.wy, albumId: 'a', original: original, replacement: replacement, expected: null);
    c.dispose();
    final stored = jsonDecode(prefs.getString(albumTrackMatchesStorageKey)!) as Map;
    stored['broken'] = {'id': 99, 'source': 'tx'};
    await prefs.setString(albumTrackMatchesStorageKey, jsonEncode(stored));
    final restored = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(restored.dispose);
    expect(restored.read(albumTrackMatchesProvider).values.single.toJson(), replacement.toJson());
  });
}
