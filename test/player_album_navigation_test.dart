import 'dart:async';

import 'package:cy_shine_music/core/api/music_api.dart';
import 'package:cy_shine_music/core/models/download_capabilities.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/models/online_collection_kind.dart';
import 'package:cy_shine_music/core/models/playlist_info.dart';
import 'package:cy_shine_music/core/music_sources/music_source_controller.dart';
import 'package:cy_shine_music/core/services/embedded_audio_tags.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/core/ui/container_transform.dart';
import 'package:cy_shine_music/features/discovery/online_playlist_detail_page.dart';
import 'package:cy_shine_music/features/downloads/download_history_entry.dart';
import 'package:cy_shine_music/features/player/player_album_navigation.dart';
import 'package:cy_shine_music/features/player/player_audio_handler.dart';
import 'package:cy_shine_music/features/player/player_controller.dart';
import 'package:cy_shine_music/features/player/player_page.dart';
import 'package:cy_shine_music/features/shell/shell_navigation.dart';
import 'package:cy_shine_music/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uses supported album identities and rejects ambiguous metadata', () {
    String? resolve(String source, Object? id, {String? mid}) {
      final music = _song(source: source, albumId: id, albumMid: mid);
      return resolvePlayerAlbum(_track(music), music)?.id;
    }

    expect(resolve('wy', 42), '42');
    expect(resolve('kw', '42'), '42');
    expect(resolve('tx', 123, mid: '003AlbumMid'), '003AlbumMid');
    expect(resolve('tx', '0015rUVB2OUdGA'), '0015rUVB2OUdGA');
    expect(resolve('tx', 'unknown'), isNull);
    expect(resolve('tx', null, mid: '..'), isNull);
    for (final id in [null, '', '0', -1, 'invalid', {}]) {
      expect(resolve('wy', id), isNull);
    }
    expect(resolve('tx', '123'), isNull);
    expect(resolve('kg', 42), isNull);
    expect(resolve('mg', 42), isNull);
    final local = PlayerTrack.fromFile('local.mp3');
    expect(resolvePlayerAlbum(local, null), isNull);
    final original = _song(albumName: 'Changes Deluxe');
    final tagged = local.withEmbeddedTags(
      const EmbeddedAudioTags(album: 'CHANGES   DELUXE'),
    );
    expect(resolvePlayerAlbum(tagged, original)?.id, '42');
    expect(resolvePlayerAlbum(tagged, _song(albumName: 'Changes')), isNull);
  });

  for (final path in [
    '/discover/albums/wy/42',
    '/player/artists/wy/person/albums/wy/42',
    '/player/albums/wy/42',
  ]) {
    testWidgets(
      'album label reveals the exact scrolled page under the player at $path',
      (tester) async {
        final h = await _pump(tester, '/songs');
        final origin = '$path?entry=saved';
        unawaited(h.router.push<void>(origin));
        await _frames(tester);
        final detail = find.byType(OnlinePlaylistDetailPage);
        final before = tester.element(detail);
        final scroll = tester
            .state<ScrollableState>(
              find
                  .descendant(of: detail, matching: find.byType(Scrollable))
                  .first,
            )
            .position;
        scroll.jumpTo(860);
        await _frames(tester);
        final offset = scroll.pixels;
        expect(offset, greaterThan(0));
        final row = find.byKey(const ValueKey('album-track-wy:track16'));
        await Scrollable.ensureVisible(tester.element(row), alignment: 0.5);
        await _frames(tester);
        expect(row.hitTestable(), findsOneWidget);
        final oldY = tester.getCenter(row).dy;
        final finalOffset = scroll.pixels;
        await tester.tap(row);
        await _frames(tester);
        expect(h.location, '/player');
        expect(h.player.currentMusic.id, 'track16');

        await tester.tap(_albumLabel);
        await _frames(tester);
        expect(h.location, origin);
        expect(tester.element(detail), same(before));
        expect(scroll.pixels, closeTo(finalOffset, 0.01));
        expect(tester.getCenter(row).dy, closeTo(oldY, 0.01));
        expect(h.api.requests, ['wy:42']);
        await tester.binding.handlePopRoute();
        await _frames(tester);
        expect(h.location, '/songs');
      },
    );
  }

  testWidgets(
    'a different provider opens its own album and all back actions restore the landscape player',
    (tester) async {
      const origin = '/discover/albums/kw/42?tab=original';
      final h = await _pump(tester, origin, size: const Size(844, 390));
      openPlayerRoute(h.router);
      await _frames(tester);
      final savedPlayer = tester.element(find.byType(PlayerPage));
      final before = h.player.snapshot;
      for (final action in ['header', 'edge', 'system']) {
        expect(_albumLabel, findsOneWidget);
        final labelPoint = tester.getCenter(_albumLabel);
        await tester.tap(_albumLabel);
        await _frames(tester);
        expect(h.location, '/player/albums/wy/42');
        final detail = tester.widget<OnlinePlaylistDetailPage>(
          find.byType(OnlinePlaylistDetailPage),
        );
        expect(detail.kind, OnlineCollectionKind.album);
        expect(detail.source, MusicSource.wy);
        final transition = find.ancestor(
          of: find.byType(OnlinePlaylistDetailPage),
          matching: find.byType(ContainerTransformTransition),
        );
        final originRect = tester
            .widget<ContainerTransformTransition>(transition)
            .origin
            ?.rect;
        expect(originRect?.contains(labelPoint), isTrue);
        if (action == 'header') {
          await tester.tap(find.byTooltip('返回').hitTestable());
        } else if (action == 'edge') {
          await tester.dragFrom(const Offset(4, 180), const Offset(285, 0));
        } else {
          await tester.binding.handlePopRoute();
        }
        await _frames(tester);
        expect(h.location, '/player');
        expect(tester.element(find.byType(PlayerPage)), same(savedPlayer));
        expect(h.player.snapshot, same(before));
      }
      await tester.binding.handlePopRoute();
      await _frames(tester);
      expect(h.location, origin);
    },
  );

  testWidgets(
    'rotating in album detail before swiping back keeps the original player and song',
    (tester) async {
      final h = await _pump(tester, '/songs', size: const Size(430, 932));
      openPlayerRoute(h.router);
      await _frames(tester);
      final player = tester.element(find.byType(PlayerPage));
      final playing = h.player.snapshot;
      await tester.tap(_albumLabel);
      await _frames(tester);
      expect(h.location, '/player/albums/wy/42');

      const landscapeInsets = FakeViewPadding(left: 59, right: 59, bottom: 21);
      tester.view.physicalSize = const Size(932, 430);
      tester.view.padding = landscapeInsets;
      tester.view.viewPadding = landscapeInsets;
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await _frames(tester);
      expect(h.location, '/player/albums/wy/42');
      await tester.dragFrom(const Offset(4, 175), const Offset(300, 0));
      await _frames(tester);
      expect(h.location, '/player');
      expect(tester.element(find.byType(PlayerPage)), same(player));
      expect(h.player.snapshot, same(playing));
      expect(_albumLabel, findsOneWidget);
      expect(h.api.requests, ['wy:42']);

      final pager = tester
          .widget<PageView>(find.byKey(const ValueKey('player-compact-pager')))
          .controller!;
      await tester.dragFrom(const Offset(721, 184), const Offset(-530, 0));
      await _frames(tester);
      expect(pager.page, 1);
      await tester.dragFrom(const Offset(200, 184), const Offset(530, 0));
      await _frames(tester);
      expect(pager.page, 0);
      await tester.tap(_albumLabel);
      await _frames(tester);
      expect(h.location, '/player/albums/wy/42');
    },
  );

  testWidgets(
    'a return hint alone does not identify an album beneath the player',
    (tester) async {
      final h = await _pump(tester, '/songs');
      unawaited(
        h.router.push<void>('/player', extra: '/discover/albums/wy/42'),
      );
      await _frames(tester);
      await tester.tap(_albumLabel);
      await _frames(tester);
      expect(h.location, '/player/albums/wy/42');
      await tester.binding.handlePopRoute();
      await _frames(tester);
      expect(h.location, '/player');
      await tester.binding.handlePopRoute();
      await _frames(tester);
      expect(h.location, '/songs');
    },
  );

  testWidgets(
    'an album name without a reliable ID stays readable without navigating',
    (tester) async {
      final h = await _pump(tester, '/player', music: _song(albumId: null));
      expect(_albumLabel, findsNothing);
      await tester.tap(find.text('同名专辑').hitTestable());
      await _frames(tester);
      expect(h.location, '/player');
      expect(h.api.requests, isEmpty);
    },
  );
}

Finder get _albumLabel =>
    find.byKey(const ValueKey('player-open-album')).hitTestable();

MusicInfo _song({
  String source = 'wy',
  Object? albumId = 42,
  String? albumMid,
  String albumName = '同名专辑',
  int index = 0,
}) => MusicInfo.fromJson({
  'id': 'track$index',
  'name': '歌曲 $index',
  'singer': '艺人',
  'source': source,
  'meta': {
    'songId': index,
    'albumName': albumName,
    'albumId': albumId,
    'albumMid': albumMid,
  },
});

PlayerTrack _track(MusicInfo music) => PlayerTrack.fromMusic(
  music: music,
  quality: Quality.k320,
  url: 'https://example.com/song',
  coverUrl: null,
);

class _Api extends MusicApi {
  final requests = <String>[];
  @override
  Future<PlaylistInfo> albumDetail({
    required String albumId,
    required MusicSource source,
  }) async {
    requests.add('${source.code}:$albumId');
    return PlaylistInfo(
      id: albumId,
      source: source,
      name: '同名专辑',
      trackCount: 40,
      tracks: [
        for (var i = 0; i < 40; i++)
          _song(source: source.code, albumId: albumId, index: i),
      ],
    );
  }
}

class _Player extends PlayerController {
  _Player(super.ref, this.music);
  MusicInfo music;
  @override
  MusicInfo get currentMusic => music;
  PlayerState get snapshot => state;
  void seed() => state = PlayerState(
    track: _track(music),
    duration: const Duration(minutes: 3),
  );
  @override
  Future<void> playFromPlaylistQueue(
    DownloadHistoryEntry entry,
    List<DownloadHistoryEntry> songs,
  ) async {
    music = entry.musicInfo!;
    seed();
  }
}

class _Harness {
  const _Harness(this.router, this.player, this.api);
  final GoRouter router;
  final _Player player;
  final _Api api;
  String get location => router.routeInformationProvider.value.uri.toString();
}

Future<_Harness> _pump(
  WidgetTester tester,
  String location, {
  Size size = const Size(390, 844),
  MusicInfo? music,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final api = _Api();
  final handler = PlayerAudioHandler();
  late _Player player;
  final router = createAppRouter(initialLocation: location);
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      playerAudioHandlerProvider.overrideWithValue(handler),
      musicApiProvider.overrideWithValue(api),
      downloadCapabilitiesProvider.overrideWithValue(
        const AsyncData(
          DownloadCapabilities(
            sources: {
              MusicSource.wy: [Quality.k320],
            },
            availableSources: [MusicSource.wy],
          ),
        ),
      ),
      playerControllerProvider.overrideWith(
        (ref) => player = _Player(ref, music ?? _song()),
      ),
    ],
  );
  addTearDown(() {
    router.dispose();
    container.dispose();
    unawaited(handler.disposeHandler());
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: ThemeData(platform: TargetPlatform.iOS),
      ),
    ),
  );
  await _frames(tester);
  player.seed();
  await _frames(tester);
  return _Harness(router, player, api);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
