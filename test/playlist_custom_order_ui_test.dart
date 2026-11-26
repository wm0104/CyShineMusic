import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/core/services/embedded_artwork_cache.dart';
import 'package:cy_shine_music/features/playlists/playlist_detail_page.dart';
import 'package:cy_shine_music/features/playlists/playlist_management_page.dart';
import 'package:cy_shine_music/features/playlists/playlist_models.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:cy_shine_music/features/playlists/widgets/playlist_track_tile.dart';
import 'package:cy_shine_music/features/shell/shell_toolbar_visibility.dart';
import 'package:cy_shine_music/features/player/player_audio_handler.dart';
import 'package:cy_shine_music/features/player/player_controller.dart';
import 'package:cy_shine_music/features/songs/widgets/songs_placeholders.dart';
import 'package:cy_shine_music/router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('same pointer from row whitespace drags in place and saves on release', (tester) async {
    final container = await _pumpPlaylist(tester);
    expect(find.byType(ReorderableDelayedDragStartListener), findsNWidgets(3));
    expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);
    await _moveFirstToEnd(tester, beforeRelease: () {
      expect(container.read(localPlaylistsProvider).single.customTrackOrder, isNull);
      expect(find.text('整理顺序'), findsNothing);
      expect(find.text('取消'), findsNothing);
      expect(find.text('完成'), findsNothing);
      expect(find.byKey(const ValueKey('immersive-playlist-header')), findsOneWidget);
      expect(find.byKey(const ValueKey('playlist-play-all')), findsOneWidget);
      expect(container.read(shellToolbarVisibleProvider), isTrue);
    });
    expect(container.read(localPlaylistsProvider).single.customOrderedTracks.map((t) => t.name), ['Bravo', 'Charlie', 'Alpha']);
    expect(find.byType(Checkbox), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('drop persists custom order, reload defaults custom, rules retain baseline', (tester) async {
    final container = await _pumpPlaylist(tester);
    final baseline = container.read(localPlaylistsProvider).single.tracks.map((track) => track.identityKey).toList();
    await _moveFirstToEnd(tester);
    expect(container.read(localPlaylistsProvider).single.customTrackOrder,
      [baseline[1], baseline[2], baseline[0]]);
    expect(container.read(localPlaylistsProvider).single.tracks.map((track) => track.identityKey), baseline);
    expect(container.read(shellToolbarVisibleProvider), isTrue);
    _expectOrder(tester, ['Bravo', 'Charlie', 'Alpha']);

    final prefs = container.read(sharedPreferencesProvider);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    final reloaded = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      playerControllerProvider.overrideWith((ref) => throw StateError('Ordering must not access the player')),
    ]);
    addTearDown(reloaded.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: reloaded,
      child: MaterialApp(home: const PlaylistDetailPage(playlistId: 'order')),
    ));
    await tester.pumpAndSettle();
    _expectOrder(tester, ['Bravo', 'Charlie', 'Alpha']);
    await tester.tap(find.byKey(const ValueKey('playlist-sort-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标题'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    _expectOrder(tester, ['Alpha', 'Bravo', 'Charlie']);
    await tester.tap(find.byKey(const ValueKey('playlist-sort-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加时间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('升序'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    _expectOrder(tester, ['Alpha', 'Bravo', 'Charlie']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search keeps query and never saves a partial reorder', (tester) async {
    final container = await _pumpPlaylist(tester);
    await tester.tap(find.byTooltip('搜索歌单歌曲'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(SongsSearchBar), 'Bravo');
    await tester.pumpAndSettle();
    final track = find.descendant(
      of: find.byType(PlaylistTrackTile), matching: find.text('Bravo'),
    );
    expect(track, findsOneWidget);
    await tester.longPress(track);
    expect(find.text('Alpha'), findsNothing);
    expect(find.byType(SongsSearchBar), findsOneWidget);
    expect(find.byType(ReorderableDelayedDragStartListener), findsNothing);
    expect(container.read(localPlaylistsProvider).single.customTrackOrder, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide layout cancelled pointer never saves a draft', (tester) async {
    final container = await _pumpPlaylist(tester, size: const Size(1200, 800));
    expect(find.byKey(const ValueKey('playlist-wide-layout')), findsOneWidget);
    await _moveFirstToEnd(tester, cancel: true);
    expect(container.read(localPlaylistsProvider).single.customTrackOrder, isNull);
    expect(container.read(shellToolbarVisibleProvider), isTrue);
    _expectOrder(tester, ['Alpha', 'Bravo', 'Charlie']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('iOS edge back exits playlist modes before leaving the detail', (
    tester,
  ) async {
    await _pumpPlaylist(tester, withAppRouter: true);

    Future<void> swipeBack() async {
      await tester.dragFrom(const Offset(4, 400), const Offset(210, 0));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byTooltip('搜索歌单歌曲'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('退出搜索'), findsOneWidget);
    await swipeBack();
    expect(find.byTooltip('退出搜索'), findsNothing);
    expect(find.byType(PlaylistDetailPage), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('playlist-batch-button')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('退出批量管理'), findsOneWidget);
    await swipeBack();
    expect(find.byTooltip('退出批量管理'), findsNothing);
    expect(find.byType(PlaylistDetailPage), findsOneWidget);

    await swipeBack();
    expect(find.byType(PlaylistManagementPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final origin in [null, 'wy', 'spotify']) {
    testWidgets('saved ${origin ?? 'manual'} playlist supports the same direct drag', (tester) async {
      final container = await _pumpPlaylist(tester, origin: origin);
      await _moveFirstToEnd(tester);
      expect(container.read(localPlaylistsProvider).single.customOrderedTracks.map((t) => t.name),
          ['Bravo', 'Charlie', 'Alpha']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cancelled card gesture leaves the saved list and original regions intact', (tester) async {
    final container = await _pumpPlaylist(tester);
    await container.read(localPlaylistsProvider.notifier).create('Second');
    await container.read(localPlaylistsProvider.notifier).create('Third');
    final baseline = container.read(localPlaylistsProvider).map((p) => p.id).toList();
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: const MaterialApp(home: PlaylistManagementPage())));
    await tester.pumpAndSettle();
    await _moveFirstToEnd(tester, cancel: true, expectMoved: false);
    expect(container.read(localPlaylistsProvider).map((p) => p.id), baseline);
    expect(find.text('整理你的音乐收藏'), findsOneWidget);
    expect(find.text('新建歌单'), findsOneWidget);
    expect(find.text('在线导入'), findsOneWidget);
    expect(find.text('洛雪导入'), findsOneWidget);
    expect(find.byTooltip('歌单选项'), findsNWidgets(3));
    expect(find.text('取消'), findsNothing);
    expect(find.text('完成'), findsNothing);
    await _moveFirstToEnd(tester, expectMoved: false, beforeRelease: () async {
      await container.read(localPlaylistsProvider.notifier).create('Concurrent');
      await tester.pump();
    });
    expect(container.read(localPlaylistsProvider).take(3).map((p) => p.id), baseline);
    expect(container.read(localPlaylistsProvider).last.name, 'Concurrent');
    expect(tester.takeException(), isNull);
  });

  testWidgets('concurrent same-identity custom order wins over a stale drop', (tester) async {
    final container = await _pumpPlaylist(tester);
    final otherOrder = container.read(localPlaylistsProvider).single.tracks
        .reversed.map((t) => t.identityKey).toList();
    await _moveFirstToEnd(tester, expectMoved: false, beforeRelease: () async {
      await container.read(localPlaylistsProvider.notifier)
          .setCustomTrackOrder('order', otherOrder);
      await tester.pump();
    });
    expect(container.read(localPlaylistsProvider).single.customTrackOrder, otherOrder);
    expect(container.read(localPlaylistsProvider).single.tracks.map((t) => t.name),
        ['Alpha', 'Bravo', 'Charlie']);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('concurrent removal rejects stale drop instead of losing songs', (tester) async {
    final container = await _pumpPlaylist(tester);
    await _moveFirstToEnd(tester, expectMoved: false, beforeRelease: () async {
      final removed = container.read(localPlaylistsProvider).single.tracks.last.identityKey;
      await container.read(localPlaylistsProvider.notifier).removeTrack('order', removed);
      await tester.pump();
    });
    expect(container.read(localPlaylistsProvider).single.customTrackOrder, isNull);
    expect(container.read(localPlaylistsProvider).single.tracks.length, 2);
    expect(find.text('整理顺序'), findsNothing);
    expect(container.read(shellToolbarVisibleProvider), isTrue);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

Future<ProviderContainer> _pumpPlaylist(WidgetTester tester, {
  Size size = const Size(390, 1000),
  bool withAppRouter = false,
  String? origin,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
  final directory = Directory.systemTemp.createTempSync('playlist-order-ui-');
  addTearDown(() => directory.deleteSync(recursive: true));
  final tracks = [
    for (final name in ['Alpha', 'Bravo', 'Charlie'])
      PlaylistTrack(
        musicId: name,
        name: name,
        singer: 'Local artist',
        albumName: '',
        sourceCode: 'local',
        qualityCode: '128k',
        localPath: (File('${directory.path}/$name.mp3')..writeAsBytesSync([])).path,
      ),
  ];
  await tester.runAsync(() async {
    for (final track in tracks) {
      await EmbeddedArtworkCache.load(track.localPath!);
    }
  });
  SharedPreferences.setMockInitialValues({
    localPlaylistsStorageKey: [jsonEncode(LocalPlaylist(
      id: 'order', name: 'Order test', tracks: tracks,
      originPlaylistId: origin == null ? null : 'saved-source',
      originSourceCode: origin,
      createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026),
    ).toJson())],
  });
  final prefs = await SharedPreferences.getInstance();
  final handler = withAppRouter ? PlayerAudioHandler() : null;
  final router = withAppRouter
      ? createAppRouter(initialLocation: '/playlists/order?from=manage')
      : null;
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    if (handler != null)
      playerAudioHandlerProvider.overrideWithValue(handler)
    else
      playerControllerProvider.overrideWith((ref) => throw StateError('Ordering must not access the player or its queue')),
  ]);
  addTearDown(() {
    router?.dispose();
    container.dispose();
    if (handler != null) unawaited(handler.disposeHandler());
  });
  if (size.width >= 840) {
    await container.read(settingsProvider.notifier).setCarPadModeEnabled(true);
  }
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: router == null
        ? MaterialApp(home: const PlaylistDetailPage(playlistId: 'order'))
        : MaterialApp.router(
            routerConfig: router,
            theme: ThemeData(platform: TargetPlatform.iOS),
          ),
  ));
  await tester.pumpAndSettle();
  return container;
}

Future<void> _moveFirstToEnd(WidgetTester tester, {
  FutureOr<void> Function()? beforeRelease,
  bool cancel = false,
  bool expectMoved = true,
}) async {
  final rows = find.byType(ReorderableDelayedDragStartListener);
  final first = tester.getRect(rows.first);
  final last = tester.getRect(rows.last);
  // Empty strip below the title/artist, not a handle or a child button.
  final start = Offset(first.left + first.width * .55, first.bottom - 3);
  final end = Offset(start.dx, last.bottom + first.height);
  final gesture = await tester.startGesture(start);
  await tester.pump(const Duration(milliseconds: 600));
  for (var step = 1; step <= 12; step++) {
    await gesture.moveTo(Offset.lerp(start, end, step / 12)!);
    await tester.pump(const Duration(milliseconds: 40));
  }
  await tester.pumpAndSettle();
  await beforeRelease?.call();
  if (cancel) {
    await gesture.cancel();
  } else {
    await gesture.up();
  }
  await tester.pumpAndSettle();
  if (!cancel && expectMoved) _expectOrder(tester, ['Bravo', 'Charlie', 'Alpha']);
}

void _expectOrder(WidgetTester tester, List<String> names) {
  for (var index = 1; index < names.length; index++) {
    expect(tester.getTopLeft(find.text(names[index - 1])).dy,
      lessThan(tester.getTopLeft(find.text(names[index])).dy));
  }
}
