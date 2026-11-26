import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/player/player_audio_handler.dart';
import 'package:cy_shine_music/features/playlists/playlist_models.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:cy_shine_music/features/playlists/widgets/playlist_track_tile.dart';
import 'package:cy_shine_music/features/songs/songs_toolbar_state.dart';
import 'package:cy_shine_music/features/songs/widgets/song_row.dart';
import 'package:cy_shine_music/router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final isManual in [true, false]) {
    testWidgets(isManual
        ? 'manual songs and detail entries read the same saved custom order'
        : 'imported songs entry keeps its old order without rewriting custom order', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1000);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final tracks = [
        for (final name in ['Alpha', 'Bravo', 'Charlie'])
          PlaylistTrack(musicId: name, name: name, singer: 'Artist',
            albumName: '', sourceCode: 'local', qualityCode: '128k'),
      ];
      final playlist = LocalPlaylist(
        id: isManual ? 'local-saved' : 'online-saved', name: 'Saved order', tracks: tracks,
        originPlaylistId: isManual ? null : 'source',
        originSourceCode: isManual ? null : 'wy',
        createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026),
        customTrackOrder: [tracks[2].identityKey, tracks[0].identityKey, tracks[1].identityKey],
      );
      SharedPreferences.setMockInitialValues({
        localPlaylistsStorageKey: [jsonEncode(playlist.toJson())],
        'songs_sort_mode_v1': SongSortMode.title.code,
        'songs_sort_ascending_v1': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final handler = PlayerAudioHandler();
      final router = createAppRouter(initialLocation: '/songs');
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        playerAudioHandlerProvider.overrideWithValue(handler),
      ]);
      addTearDown(() {
        router.dispose();
        container.dispose();
        unawaited(handler.disposeHandler());
      });
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      await _pumpUi(tester);
      await tester.tap(find.byKey(const ValueKey('library-view-menu-anchor')));
      await _pumpUi(tester);
      await tester.tap(find.text(playlist.name));
      await _pumpUi(tester);
      expect(container.read(songsLibraryPlaylistIdProvider), playlist.id);
      List<String> names() => tester.widgetList<SongRow>(find.byType(SongRow))
          .map((row) => row.entry.name).toList();
      final expectedInitial = isManual
          ? ['Charlie', 'Alpha', 'Bravo'] : ['Alpha', 'Bravo', 'Charlie'];
      expect(names(), expectedInitial);
      expect(find.byType(ReorderableDelayedDragStartListener), findsNothing);
      // Compare the two real entry points, rather than only a model getter.
      router.push('/playlists/${playlist.id}');
      await _pumpUi(tester);
      expect(tester.widgetList<PlaylistTrackTile>(find.byType(PlaylistTrackTile))
          .map((tile) => tile.item.track.name), ['Charlie', 'Alpha', 'Bravo']);
      expect(container.read(localPlaylistsProvider).single.customTrackOrder,
          playlist.customTrackOrder);
      await _dragDetail(tester, firstToLast: true);
      expect(container.read(localPlaylistsProvider).single.customOrderedTracks.map((t) => t.name),
          ['Alpha', 'Bravo', 'Charlie']);
      router.pop();
      await _pumpUi(tester);
      expect(names(), ['Alpha', 'Bravo', 'Charlie']);

      // Re-enter and drag in the opposite direction; SongsPage must read the
      // latest provider value, not a one-time copy or its default title sort.
      router.push('/playlists/${playlist.id}');
      await _pumpUi(tester);
      await _dragDetail(tester, firstToLast: false);
      router.pop();
      await _pumpUi(tester);
      final expectedFinal = isManual
          ? ['Alpha', 'Charlie', 'Bravo'] : ['Alpha', 'Bravo', 'Charlie'];
      expect(names(), expectedFinal);
      expect(container.read(localPlaylistsProvider).single.customOrderedTracks.map((t) => t.name),
          ['Alpha', 'Charlie', 'Bravo']);
      expect(container.read(localPlaylistsProvider).single.tracks.map((t) => t.identityKey),
          tracks.map((t) => t.identityKey));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final restartedRouter = createAppRouter(initialLocation: '/songs');
      final restarted = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        playerAudioHandlerProvider.overrideWithValue(handler),
      ]);
      addTearDown(() {
        restartedRouter.dispose();
        restarted.dispose();
      });
      await tester.pumpWidget(UncontrolledProviderScope(
        container: restarted,
        child: MaterialApp.router(routerConfig: restartedRouter),
      ));
      await _pumpUi(tester);
      expect(names(), expectedFinal);
      expect(restarted.read(localPlaylistsProvider).single.customTrackOrder,
          [tracks[0].identityKey, tracks[2].identityKey, tracks[1].identityKey]);
      expect(handler.queue.value, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _dragDetail(WidgetTester tester, {required bool firstToLast}) async {
  final rows = find.byType(ReorderableDelayedDragStartListener);
  final first = tester.getRect(rows.first);
  final last = tester.getRect(rows.last);
  final source = firstToLast ? first : last;
  final start = Offset(source.left + source.width * .55, source.bottom - 3);
  final middle = tester.getRect(rows.at(1));
  final end = Offset(start.dx,
      firstToLast ? last.bottom + first.height : middle.bottom - 8);
  final gesture = await tester.startGesture(start);
  await tester.pump(const Duration(milliseconds: 600));
  for (var step = 1; step <= 12; step++) {
    await gesture.moveTo(Offset.lerp(start, end, step / 12)!);
    await tester.pump(const Duration(milliseconds: 40));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _pumpUi(WidgetTester tester) async {
  for (var index = 0; index < 12; index++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
