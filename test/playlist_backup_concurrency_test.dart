import 'dart:async';
import 'dart:convert';

import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/playlists/playlist_models.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late _DelayedPreferences delayed;
  late ProviderContainer container;

  Future<LocalPlaylistNotifier> open(List<Map<String, dynamic>> tracks) async {
    await prefs.setStringList(localPlaylistsStorageKey, [jsonEncode(_playlist(tracks))]);
    delayed = _DelayedPreferences(prefs);
    container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(delayed)]);
    return container.read(localPlaylistsProvider.notifier);
  }

  Future<LocalPlaylist> reload() async {
    await prefs.reload();
    container.invalidate(localPlaylistsProvider);
    return container.read(localPlaylistsProvider).single;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  tearDown(() => container.dispose());

  test('backup awaiting storage cannot replace newer local additions, custom order or manual choices', () async {
    final store = await open([_spotify(), _track('a'), _track('b')]);
    final expected = container.read(localPlaylistsProvider).single.tracks.first;
    final importing = store.importBackup(_backup([_spotify(match: 'remote-choice'), _track('c')]));
    await delayed.started.future;
    final adding = store.addMusics('p', [_music('local-new')]);
    final ordering = store.setCustomTrackOrder('p', [
      'music:wy:local-new', 'music:wy:b', expected.identityKey, 'music:wy:a',
    ]);
    final matching = store.setSpotifyTrackMatch('p', expected: expected, music: _music('new-manual'));
    delayed.release.complete();
    expect(await importing, 1);
    await adding;
    await ordering;
    expect(await matching, isTrue);

    void verify(LocalPlaylist playlist) {
      expect(playlist.customOrderedTracks.map((t) => t.musicId), ['local-new', 'b', 'new-manual', 'a', 'c']);
      final spotify = playlist.tracks.singleWhere((t) => t.spotify != null);
      expect(spotify.spotifyMatchIsManual, isTrue);
      expect(spotify.musicInfo!.id, 'new-manual');
    }
    verify(container.read(localPlaylistsProvider).single);
    verify(await reload());
  });

  test('backup awaiting storage preserves a completed download attachment and the newest order after reload', () async {
    final store = await open([_track('a'), _track('b')]);
    final importing = store.importBackup(_backup([_track('a'), _track('c')]));
    await delayed.started.future;
    final attaching = store.attachDownload(music: _music('a'), quality: Quality.flac, localPath: '/existing/download.flac');
    final ordering = store.setCustomTrackOrder('p', ['music:wy:b', 'music:wy:a']);
    delayed.release.complete();
    expect(await importing, 1);
    expect(await attaching, 1);
    await ordering;
    final playlist = await reload();
    expect(playlist.customOrderedTracks.map((t) => t.musicId), ['b', 'a', 'c']);
    final track = playlist.tracks.singleWhere((t) => t.musicId == 'a');
    expect(track.localPath, '/existing/download.flac');
    expect(track.qualityCode, Quality.flac.code);
  });

  test('a rebased no-op keeps the local version when the user already supplied the missing track', () async {
    final store = await open([_track('a')]);
    final importing = store.importBackup(_backup([_track('a'), _track('c')]));
    await delayed.started.future;
    final adding = store.addMusics('p', [_music('c')]);
    delayed.release.complete();
    expect(await importing, 0);
    expect(await adding, 1);
    final playlist = await reload();
    expect(playlist.customOrderedTracks.map((t) => t.musicId), ['a', 'c']);
    expect(playlist.tracks.singleWhere((t) => t.musicId == 'c').musicInfo!.id, 'c');
  });

  test('concurrent imports rebase before publication and their durable result contains both additions', () async {
    final store = await open([_track('a')]);
    final first = store.importBackup(_backup([_track('a'), _track('c')]));
    await delayed.started.future;
    final second = store.importBackup(_backup([_track('a'), _track('d')]));
    delayed.release.complete();
    await first;
    await second;
    final playlist = await reload();
    final ids = playlist.customOrderedTracks.map((t) => t.musicId).toList();
    expect(ids.first, 'a');
    expect(ids, unorderedEquals(['a', 'c', 'd']));
  });
}

/// Blocks the first durable write, not merely the read/cache, so the old
/// importer deterministically publishes its stale snapshot after local edits.
class _DelayedPreferences implements SharedPreferences {
  _DelayedPreferences(this.delegate);
  final SharedPreferences delegate;
  final started = Completer<void>();
  final release = Completer<void>();
  bool _blocked = false;

  @override
  Object? get(String key) => delegate.get(key);

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    final rows = List<String>.of(value);
    if (key == localPlaylistsStorageKey && !_blocked) {
      _blocked = true;
      started.complete();
      await release.future;
    }
    return delegate.setStringList(key, rows);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _backup(List<Map<String, dynamic>> tracks) => jsonEncode({
  'format': 'cyshine-playlist-backup', 'version': 1, 'playlists': [_playlist(tracks)],
});
Map<String, dynamic> _playlist(List<Map<String, dynamic>> tracks) => {
  'version': 1, 'id': 'p', 'name': 'local', 'tracks': tracks,
  'createdAt': '2026-01-01T00:00:00.000', 'updatedAt': '2026-01-01T00:00:00.000',
  'customTrackOrder': tracks.map((t) => PlaylistTrack.tryFromJson(t)!.identityKey).toList(),
  'movedOutTrackIds': <String>[],
};
Map<String, dynamic> _track(String id) => {
  'musicId': id, 'name': id, 'singer': 'artist', 'albumName': '', 'source': 'wy', 'quality': '128k',
};
MusicInfo _music(String id) => MusicInfo.fromJson({
  'id': id, 'name': id, 'singer': 'artist', 'source': 'wy',
  'meta': {'songId': id, 'albumName': '', 'qualitys': []},
});
Map<String, dynamic> _spotify({String match = 'old-manual'}) => {
  ..._track(match), 'musicInfo': _music(match).toJson(), 'spotifyMatchIsManual': true,
  'spotify': {'uri': 'spotify:track:original', 'title': 'original', 'artist': 'artist', 'occurrence': 0, 'type': 'track'},
};
