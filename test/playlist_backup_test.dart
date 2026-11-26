import 'dart:convert';

import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/playlists/playlist_models.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late ProviderContainer container;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
    ]);
  });
  tearDown(() => container.dispose());

  test('full backup round trips local files, Spotify occurrences, manual picks and order', () async {
    final rows = [_playlist('p', tracks: [_local(), _spotify(0), _spotify(1)], moved: ['spotify:spotify:track:abc:2'])];
    rows.first.addAll({
      'originPlaylistId': 'spotify-list', 'originSource': 'spotify',
      'onlineTrackIds': ['spotify:spotify:track:abc:0', 'spotify:spotify:track:abc:1', 'spotify:spotify:track:abc:2'],
      'movedOutTrackProviders': {'spotify:spotify:track:abc:2': 'music:wy:old-choice'},
      'customTrackOrder': ['spotify:spotify:track:abc:1', 'file:/not-on-this-device/a.mp3', 'spotify:spotify:track:abc:0'],
    });
    await prefs.setStringList(localPlaylistsStorageKey, rows.map(jsonEncode).toList());
    final store = container.read(localPlaylistsProvider.notifier);
    final before = container.read(localPlaylistsProvider).single;
    final backup = store.exportBackup();
    await store.delete('p');
    expect(await store.importBackup(backup), 1);
    final after = container.read(localPlaylistsProvider).single;
    expect(after.toJson(), before.toJson());
    expect(after.tracks.where((t) => t.spotify != null).length, 2);
    expect(after.tracks.last.spotifyMatchIsManual, isTrue);
    expect(after.tracks.first.localPath, '/not-on-this-device/a.mp3');
    expect(await store.importBackup(backup), 0);
  });

  test('merge preserves local name, choices and order, appends missing and respects moved-out ids', () async {
    final local = _playlist('p', tracks: [_spotify(0)], moved: ['music:wy:removed']);
    await prefs.setStringList(localPlaylistsStorageKey, [jsonEncode(local)]);
    final store = container.read(localPlaylistsProvider.notifier);
    final incoming = _playlist('p', tracks: [_spotify(1), _spotify(0, matchId: 'remote-choice'), _track('removed'), _track('new')]);
    incoming['name'] = 'remote rename';
    final original = container.read(localPlaylistsProvider).single.tracks.first;
    final backup = _backup([incoming, _playlist('other', tracks: [])]);
    expect(await store.importBackup(backup), 3);
    final merged = container.read(localPlaylistsProvider);
    expect(merged.map((p) => p.id), ['p', 'other']);
    expect(merged.first.name, 'Playlist p');
    expect(merged.first.tracks.first.toJson(), original.toJson());
    expect(merged.first.customOrderedTracks.map((t) => t.musicId), ['matched', 'matched', 'new']);
    expect(await store.importBackup(backup), 0);
  });

  test('existing card and custom track order survive while missing rows append in backup order', () async {
    final p = _playlist('p', tracks: [_track('a'), _track('b')]);
    p['customTrackOrder'] = ['music:wy:b', 'music:wy:a'];
    await prefs.setStringList(localPlaylistsStorageKey, [jsonEncode(p), jsonEncode(_playlist('q', tracks: []))]);
    final store = container.read(localPlaylistsProvider.notifier);
    final backup = _backup([
      _playlist('new-second', tracks: []),
      _playlist('q', tracks: []),
      _playlist('p', tracks: [_track('a'), _track('c'), _track('b'), _track('d')]),
      _playlist('new-last', tracks: []),
    ]);
    expect(await store.importBackup(backup), 4);
    expect(container.read(localPlaylistsProvider).map((p) => p.id), ['p', 'q', 'new-second', 'new-last']);
    expect(container.read(localPlaylistsProvider).first.customOrderedTracks.map((t) => t.musicId), ['b', 'a', 'c', 'd']);
    final snapshot = store.exportBackup();
    expect(await store.importBackup(backup), 0);
    expect(store.exportBackup(), snapshot);
  });

  test('ordinary online identities must agree with their playable payload or the entire backup stays unapplied', () async {
    final store = container.read(localPlaylistsProvider.notifier);
    await store.create('keep');
    final before = store.exportBackup();
    final stored = prefs.getStringList(localPlaylistsStorageKey);
    for (final track in [
      _onlineTrack(innerSource: 'tx'),
      _onlineTrack(innerId: 'different-id'),
      _onlineTrack(outerSource: 'unknown', innerSource: 'unknown'),
      _onlineTrack(innerSource: 'unknown'),
      _onlineTrack(outerSource: 'unknown'),
      _onlineTrack(outerSource: 'all', innerSource: 'all'),
    ]) {
      final text = _backup([
        _playlist('valid-first', tracks: [_track('valid')]),
        _playlist('invalid-last', tracks: [track]),
      ]);
      final current = container.read(localPlaylistsProvider.notifier);
      await expectLater(current.importBackup(text), throwsFormatException);
      expect(current.exportBackup(), before);
      expect(prefs.getStringList(localPlaylistsStorageKey), stored);
      await prefs.reload();
      container.invalidate(localPlaylistsProvider);
      expect(container.read(localPlaylistsProvider.notifier).exportBackup(), before);
    }
  });

  test('strict online validation still round trips local files and matched/unmatched Spotify occurrences', () async {
    final unmatched = _spotify(2);
    unmatched['musicId'] = 'spotify:track:abc';
    unmatched['source'] = 'spotify';
    unmatched.remove('musicInfo');
    unmatched.remove('spotifyMatchIsManual');
    final text = _backup([_playlist('p', tracks: [
      _local(), _onlineTrack(), _spotify(0), _spotify(1), unmatched,
    ])]);
    final store = container.read(localPlaylistsProvider.notifier);
    expect(await store.importBackup(text), 1);
    final saved = store.exportBackup();
    final playlist = container.read(localPlaylistsProvider).single;
    expect(playlist.tracks.first.localPath, '/not-on-this-device/a.mp3');
    expect(playlist.tracks.where((t) => t.spotify != null), hasLength(3));
    expect(playlist.tracks.last.isUnmatchedSpotify, isTrue);
    expect(playlist.tracks[2].spotifyMatchIsManual, isTrue);
    await store.delete('p');
    expect(await store.importBackup(saved), 1);
    expect(store.exportBackup(), saved);
  });

  test('damaged, duplicate and unknown version backups never partially write', () async {
    final store = container.read(localPlaylistsProvider.notifier);
    await store.create('keep');
    final before = store.exportBackup();
    final stored = prefs.getStringList(localPlaylistsStorageKey);
    for (final invalid in [
      '{bad',
      jsonEncode({'format': 'cyshine-playlist-backup', 'version': 99, 'playlists': []}),
      _backup([_playlist('a', tracks: []), {'id': 'bad'}]),
      _backup([_playlist('a', tracks: []), _playlist('a', tracks: [])]),
      _backup([_playlist('a', tracks: [_spotify(0), _spotify(0)])]),
    ]) {
      await expectLater(store.importBackup(invalid), throwsA(isA<FormatException>()));
      expect(store.exportBackup(), before);
      expect(prefs.getStringList(localPlaylistsStorageKey), stored);
    }
  });
}

String _backup(List<Map<String, dynamic>> rows) => jsonEncode({
  'format': 'cyshine-playlist-backup', 'version': 1, 'playlists': rows,
});
Map<String, dynamic> _playlist(String id, {required List<Map<String, dynamic>> tracks, List<String> moved = const []}) => {
  'version': 1, 'id': id, 'name': 'Playlist $id', 'tracks': tracks,
  'createdAt': '2026-01-01T00:00:00.000', 'updatedAt': '2026-01-01T00:00:00.000',
  'customTrackOrder': tracks.map((t) => PlaylistTrack.tryFromJson(t)!.identityKey).toList(),
  'movedOutTrackIds': moved,
};
Map<String, dynamic> _track(String id) => {
  'musicId': id, 'name': id, 'singer': 'artist', 'albumName': '',
  'source': 'wy', 'quality': '128k',
};
Map<String, dynamic> _local() => {
  ..._track(''), 'source': '', 'localPath': '/not-on-this-device/a.mp3',
};
Map<String, dynamic> _spotify(int occurrence, {String matchId = 'matched'}) => {
  ..._track(matchId),
  'spotify': {'uri': 'spotify:track:abc', 'title': 'original', 'artist': 'artist', 'occurrence': occurrence, 'type': 'track'},
  'spotifyMatchIsManual': true,
  'musicInfo': {'id': matchId, 'name': 'chosen', 'singer': 'artist', 'source': 'wy', 'meta': {'songId': matchId, 'albumName': '', 'qualitys': []}},
};

Map<String, dynamic> _onlineTrack({
  String outerSource = 'wy', String innerSource = 'wy', String innerId = 'online-id',
}) => {
  ..._track('online-id'), 'source': outerSource,
  'musicInfo': {
    'id': innerId, 'name': 'playable', 'singer': 'artist', 'source': innerSource,
    'meta': {'songId': innerId, 'albumName': '', 'qualitys': []},
  },
};
