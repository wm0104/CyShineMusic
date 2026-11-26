import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/api/music_api.dart';
import 'package:cy_shine_music/core/models/album_info.dart';
import 'package:cy_shine_music/core/models/artist_info.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/models/online_collection_kind.dart';
import 'package:cy_shine_music/core/models/playlist_info.dart';
import 'package:cy_shine_music/core/models/search_response.dart';
import 'package:cy_shine_music/features/search/search_page.dart';
import 'package:cy_shine_music/features/search/search_controller.dart' show SearchCategory, searchControllerProvider;
import 'package:cy_shine_music/core/models/download_capabilities.dart';
import 'package:cy_shine_music/core/music_sources/music_source_controller.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/discovery/album_track_match_store.dart';
import 'package:cy_shine_music/features/discovery/discovery_controller.dart';
import 'package:cy_shine_music/features/discovery/online_playlist_detail_page.dart';
import 'package:cy_shine_music/features/downloads/download_history_store.dart';
import 'package:cy_shine_music/features/player/player_audio_handler.dart';
import 'package:cy_shine_music/features/player/player_controller.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:cy_shine_music/features/search/widgets/album_result_tile.dart';
import 'package:cy_shine_music/features/search/widgets/source_filter_chips.dart';
import 'package:cy_shine_music/router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('partial album responses are errors, never a selectable full album', () async {
    final api = _Api(incomplete: true);
    final container = ProviderContainer(overrides: [musicApiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);
    await expectLater(container.read(onlinePlaylistDetailProvider(const OnlinePlaylistKey(
      source: MusicSource.wy, id: 'record', kind: OnlineCollectionKind.album,
    )).future), throwsStateError);
  });

  test('album detail requests complete album, never the playlist parser', () async {
    final api = _Api();
    final container = ProviderContainer(overrides: [musicApiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);
    final detail = await container.read(onlinePlaylistDetailProvider(const OnlinePlaylistKey(
      source: MusicSource.wy, id: 'record', kind: OnlineCollectionKind.album,
    )).future);
    expect(detail.tracks, hasLength(65));
    expect(detail.tracks.last.id, 'wy_64');
    expect(api.albumRequests, ['wy:record']);
  });

  testWidgets('artist songs default, album catalog uses artist ID and never plays', (tester) async {
    final h = await _pump(tester, '/discover/artists/wy/person');
    expect(find.byType(SearchSegments), findsOneWidget);
    expect(h.api.catalogRequests, isEmpty);
    await _albums(tester);
    expect(h.api.catalogRequests, ['wy:person:0']);
    expect(find.text('发行专辑'), findsOneWidget);
    expect(find.text('播放全部').hitTestable(), findsNothing);
    expect(h.player.played, isEmpty);
    await tester.tap(find.byKey(const ValueKey('album-wy-record')));
    await _frames(tester);
    expect(h.location, '/discover/albums/wy/record');
    expect(h.api.albumRequests, ['wy:record']);
    expect(find.text('收藏歌单'), findsNothing);
    expect(find.byKey(const ValueKey('playlist-favorite')), findsNothing);
    expect(h.player.played, isEmpty);
  });

  testWidgets('song failure retains album segment and catalog access', (tester) async {
    final h = await _pump(tester, '/discover/artists/wy/person', songsFail: true);
    expect(find.byKey(const ValueKey('artist-content-albums')), findsOneWidget);
    await _albums(tester);
    expect(find.text('发行专辑'), findsOneWidget);
    expect(h.player.played, isEmpty);
  });

  testWidgets('catalog empty, unsupported and failure are distinct; retry preserves artist', (tester) async {
    final h = await _pump(tester, '/discover/artists/wy/person', catalog: 'error');
    await _albums(tester);
    expect(find.textContaining('offline albums'), findsOneWidget);
    h.api.catalog = 'empty';
    await tester.ensureVisible(find.byTooltip('重试'));
    await tester.tap(find.byTooltip('重试'));
    await _frames(tester);
    expect(find.text('暂无可用专辑'), findsOneWidget);
    expect(h.api.catalogRequests, everyElement(startsWith('wy:person:')));
  });

  testWidgets('unsupported catalog is not presented as empty', (tester) async {
    await _pump(tester, '/discover/artists/wy/person', catalog: 'unsupported');
    await _albums(tester);
    expect(find.textContaining('不支持'), findsOneWidget);
    expect(find.text('暂无可用专辑'), findsNothing);
  });

  testWidgets('catalog loads the next server page explicitly', (tester) async {
    final h = await _pump(tester, '/discover/artists/wy/person', catalog: 'paged');
    await _albums(tester);
    await tester.ensureVisible(find.text('加载更多专辑'));
    await tester.tap(find.text('加载更多专辑'));
    await _frames(tester);
    expect(h.api.catalogRequests, ['wy:person:0', 'wy:person:30']);
    expect(find.text('第二张专辑'), findsOneWidget);
  });

  testWidgets('artist album versions share one row and request only the chosen ID', (tester) async {
    final h = await _pump(tester, '/discover/artists/wy/person', catalog: 'versions');
    await _albums(tester);
    expect(find.text('发行专辑'), findsOneWidget);
    expect(find.textContaining('2 个版本'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('album-wy-record')));
    await _frames(tester);
    expect(h.api.albumRequests, isEmpty);
    expect(find.text('版本 1 · 2025-09-05'), findsOneWidget);
    expect(find.text('版本 2 · 2025-09-05'), findsOneWidget);
    expect(find.byKey(const ValueKey('album-versions-wy-record-barrier')), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await _frames(tester);
    expect(h.location, '/discover/artists/wy/person');
    expect(h.api.albumRequests, isEmpty);
    await tester.tap(find.byKey(const ValueKey('album-wy-record')));
    await _frames(tester);
    await tester.tap(find.text('版本 2 · 2025-09-05'));
    await _frames(tester);
    expect(h.location, '/discover/albums/wy/record-version');
    expect(h.api.albumRequests, ['wy:record-version']);
    expect(h.player.played, isEmpty);
  });

  testWidgets('later album pages add versions while preserving different counts', (tester) async {
    final h = await _pump(tester, '/discover/artists/wy/person', catalog: 'paged-versions');
    await _albums(tester);
    expect(find.textContaining('个版本'), findsNothing);
    await tester.ensureVisible(find.text('加载更多专辑'));
    await tester.tap(find.text('加载更多专辑'));
    await _frames(tester);
    expect(h.api.catalogRequests, ['wy:person:0', 'wy:person:30']);
    expect(find.text('发行专辑'), findsNWidgets(2));
    expect(find.textContaining('2 个版本'), findsOneWidget);
    expect(find.byKey(const ValueKey('album-wy-record-version')), findsNothing);
    expect(find.byKey(const ValueKey('album-wy-record-short')), findsOneWidget);
    expect(h.api.albumRequests, isEmpty);
  });

  testWidgets('chosen album version preserves the playback artist stack', (tester) async {
    final h = await _pump(tester, '/player/artists/wy/person', catalog: 'versions');
    await _albums(tester);
    await tester.tap(find.byKey(const ValueKey('album-wy-record')));
    await _frames(tester);
    await tester.tap(find.text('版本 2 · 2025-09-05'));
    await _frames(tester);
    expect(h.location, '/player/artists/wy/person/albums/wy/record-version');
    expect(h.api.albumRequests, ['wy:record-version']);
    await tester.tap(find.byTooltip('返回'));
    await _frames(tester);
    expect(h.location, '/player/artists/wy/person');
    expect(find.text('发行专辑'), findsOneWidget);
    expect(find.textContaining('2 个版本'), findsOneWidget);
    expect(h.player.played, isEmpty);
  });

  testWidgets('album row callback override does not navigate', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(ProviderScope(child: MaterialApp(home: Scaffold(
      body: AlbumResultTile(album: _album, onTap: () => tapped++),
    ))));
    await tester.tap(find.text('发行专辑'));
    expect(tapped, 1);
  });

  testWidgets('playback artist album route stays in the original artist stack', (tester) async {
    final h = await _pump(tester, '/player/artists/wy/person');
    await _albums(tester);
    await tester.tap(find.byKey(const ValueKey('album-wy-record')));
    await _frames(tester);
    expect(h.location, '/player/artists/wy/person/albums/wy/record');
    expect(tester.widget<OnlinePlaylistDetailPage>(find.byType(OnlinePlaylistDetailPage)).kind,
      OnlineCollectionKind.album);
    expect(h.player.played, isEmpty);
    await tester.tap(find.byTooltip('返回'));
    await _frames(tester);
    expect(h.location, '/player/artists/wy/person');
    expect(find.text('发行专辑'), findsOneWidget);
  });

  testWidgets('complete album select all chooses one destination and adds all 65 in order', (tester) async {
    final h = await _pump(tester, '/discover/albums/wy/record');
    final target = await h.container.read(localPlaylistsProvider.notifier).create('目标歌单');
    await _frames(tester);
    await _selectAll(tester);
    final navigation = find.byTooltip('设置').hitTestable();
    expect(navigation, findsOneWidget);
    expect(tester.getBottomLeft(find.byKey(const ValueKey('playlist-batch-bottom-bar'))).dy,
      lessThanOrEqualTo(tester.getTopLeft(navigation).dy));
    await tester.tap(find.text('添加到歌单').hitTestable());
    await _frames(tester);
    expect(find.text('添加歌曲到'), findsOneWidget);
    await tester.tap(find.text('目标歌单').hitTestable());
    await _frames(tester);
    final stored = h.container.read(localPlaylistsProvider.notifier).byId(target.id)!;
    expect(stored.tracks, hasLength(65));
    expect(stored.tracks.map((track) => track.musicInfo?.id),
      List.generate(65, (index) => 'wy_$index'));
    expect(stored.customOrderedTracks.map((track) => track.musicInfo?.id),
      List.generate(65, (index) => 'wy_$index'));
    expect(stored.tracks.last.musicInfo?.id, 'wy_64');
    expect(find.text('添加歌曲到'), findsNothing);
    expect(h.player.played, isEmpty);
    await _finishToast(tester);
  });

  testWidgets('album addition deduplicates while retaining existing target and custom order', (tester) async {
    final h = await _pump(tester, '/discover/albums/wy/record');
    final store = h.container.read(localPlaylistsProvider.notifier);
    final target = await store.create('已有曲目目标');
    await store.addMusics(target.id, [_song(0), _song(64)]);
    final before = store.byId(target.id)!;
    await store.setCustomTrackOrder(target.id,
      before.tracks.reversed.map((track) => track.identityKey).toList());
    final beforeCustom = List<String>.of(store.byId(target.id)!.customTrackOrder!);
    await _frames(tester);
    await _selectAll(tester);
    await tester.tap(find.text('添加到歌单').hitTestable());
    await _frames(tester);
    expect(find.text('添加歌曲到'), findsOneWidget);
    await tester.tap(find.text('已有曲目目标').hitTestable());
    await _frames(tester);
    final stored = store.byId(target.id)!;
    expect(stored.tracks, hasLength(65));
    // addMusics prepends only new tracks; existing raw/custom orders are kept.
    expect(stored.tracks.map((track) => track.musicInfo?.id),
      [for (var index = 1; index < 64; index++) 'wy_$index', 'wy_0', 'wy_64']);
    expect(stored.customOrderedTracks.map((track) => track.musicInfo?.id),
      ['wy_64', 'wy_0', for (var index = 1; index < 64; index++) 'wy_$index']);
    expect(stored.customTrackOrder!.take(2), beforeCustom);
    expect(h.api.full.tracks.map((music) => music.id),
      List.generate(65, (index) => 'wy_$index'));
    expect(find.text('添加歌曲到'), findsNothing);
    expect(h.player.played, isEmpty);
    await _finishToast(tester);
  });

  testWidgets('cancel destination writes nothing and leaves selection intact', (tester) async {
    final h = await _pump(tester, '/discover/albums/wy/record');
    final target = await h.container.read(localPlaylistsProvider.notifier).create('目标歌单');
    await _selectAll(tester);
    await tester.tap(find.text('添加到歌单').hitTestable());
    await _frames(tester);
    Navigator.of(tester.element(find.text('添加歌曲到')), rootNavigator: true).pop();
    await _frames(tester);
    expect(h.container.read(localPlaylistsProvider.notifier).byId(target.id)!.tracks, isEmpty);
    expect(find.text('播放 65 首'), findsOneWidget);
    expect(h.player.played, isEmpty);
  });

  testWidgets('remembered replacement is added without rewriting original album or playing', (tester) async {
    final h = await _pump(tester, '/discover/albums/wy/record');
    final original = _song(0);
    final replacement = MusicInfo.fromJson({
      'id': 'tx_selected', 'name': '手选版本', 'singer': '艺人', 'source': 'tx',
      'meta': {'songId': 'selected'},
    });
    await h.container.read(albumTrackMatchesProvider.notifier).setMatch(
      source: MusicSource.wy, albumId: 'record', original: original,
      replacement: replacement, expected: null,
    );
    final target = await h.container.read(localPlaylistsProvider.notifier).create('目标歌单');
    await _frames(tester);
    expect(find.text('原曲 0'), findsOneWidget);
    expect(find.text('手选版本'), findsNothing);
    await _selectAll(tester);
    await tester.tap(find.text('添加到歌单').hitTestable());
    await _frames(tester);
    await tester.tap(find.text('目标歌单').hitTestable());
    await _frames(tester);
    expect(h.container.read(localPlaylistsProvider.notifier).byId(target.id)!.tracks.first.musicInfo?.id,
      'tx_selected');
    expect(h.api.full.tracks.first.id, 'wy_0');
    expect(h.player.played, isEmpty);
    await _finishToast(tester);
  });
  testWidgets('single album song uses the existing destination sheet once', (tester) async {
    final h = await _pump(tester, '/discover/albums/wy/record');
    final target = await h.container.read(localPlaylistsProvider.notifier).create('单首目标');
    await _frames(tester);
    await _slideFirst(tester);
    await tester.tap(find.text('添加到歌单').hitTestable());
    await _frames(tester);
    expect(find.text('添加歌曲到'), findsOneWidget);
    await tester.tap(find.text('单首目标').hitTestable());
    await _frames(tester);
    expect(h.container.read(localPlaylistsProvider.notifier).byId(target.id)!.tracks.single.musicInfo?.id, 'wy_0');
    expect(find.text('添加歌曲到'), findsNothing);
    expect(h.player.played, isEmpty);
    await _finishToast(tester);
  });

  testWidgets('explicit play all uses all album tracks in order with album queue identity', (tester) async {
    final h = await _pump(tester, '/discover/albums/wy/record');
    final button = find.byKey(const ValueKey('playlist-play-all'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await _frames(tester);
    expect(h.player.queues.single, hasLength(65));
    expect(h.player.queues.single.map((entry) => entry.musicId), List.generate(65, (i) => 'wy_$i'));
    expect(h.player.queues.single.every((entry) => entry.id.startsWith('playlist:album:wy:record:')), isTrue);
    expect(h.player.queues.single.every((entry) => entry.preservePlaylistPosition), isTrue);
  });

  testWidgets('manual match saves through existing picker and returns without playback', (tester) async {
    final h = await _pump(tester, '/discover/albums/wy/record');
    await _openMatch(tester);
    expect(find.byType(SearchPage), findsOneWidget);
    await tester.tap(find.text('可选版本'));
    await _frames(tester);
    final key = albumTrackMatchKey(source: MusicSource.wy, albumId: 'record', original: _song(0));
    expect(h.container.read(albumTrackMatchesProvider)[key]?.id, _candidate.id);
    expect(find.byType(SearchPage), findsNothing);
    expect(find.text('原曲 0'), findsOneWidget);
    expect(h.player.played, isEmpty);
    await _finishToast(tester);
  });

  testWidgets('cancelling match keeps the previous manual version', (tester) async {
    final h = await _pump(tester, '/discover/albums/wy/record');
    await h.container.read(albumTrackMatchesProvider.notifier).setMatch(
      source: MusicSource.wy, albumId: 'record', original: _song(0),
      replacement: _candidate, expected: null,
    );
    await _frames(tester);
    await _openMatch(tester);
    Navigator.of(tester.element(find.byType(SearchPage))).pop();
    await _frames(tester);
    final key = albumTrackMatchKey(source: MusicSource.wy, albumId: 'record', original: _song(0));
    expect(h.container.read(albumTrackMatchesProvider)[key], same(_candidate));
    expect(h.player.played, isEmpty);
  });

  testWidgets('an older open picker cannot overwrite a newer persisted match', (tester) async {
    final h = await _pump(tester, '/discover/albums/wy/record');
    await _openMatch(tester);
    final newer = _song(64);
    await h.container.read(albumTrackMatchesProvider.notifier).setMatch(
      source: MusicSource.wy, albumId: 'record', original: _song(0),
      replacement: newer, expected: null,
    );
    await tester.tap(find.text('可选版本'));
    await _frames(tester);
    final key = albumTrackMatchKey(source: MusicSource.wy, albumId: 'record', original: _song(0));
    expect(h.container.read(albumTrackMatchesProvider)[key], same(newer));
    expect(h.player.played, isEmpty);
    await _finishToast(tester);
  });

  testWidgets('discovery album search opens the same full-detail route as the artist catalog', (tester) async {
    final h = await _pump(tester, '/discover/artists/wy/person');
    h.container.read(searchControllerProvider.notifier).setCategory(SearchCategory.albums);
    await h.container.read(searchControllerProvider.notifier).search(keyword: '发行', source: MusicSource.wy);
    h.router.go('/');
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('album-wy-record')));
    await _frames(tester);
    expect(h.location, '/discover/albums/wy/record');
    expect(h.api.albumRequests, ['wy:record']);
    expect(h.player.played, isEmpty);
  });

  testWidgets('two selected album songs use one destination and preserve original order', (tester) async {
    final h = await _pump(tester, '/discover/albums/wy/record');
    final target = await h.container.read(localPlaylistsProvider.notifier).create('多选目标');
    await tester.ensureVisible(find.byTooltip('批量操作'));
    await tester.tap(find.byTooltip('批量操作'));
    await _frames(tester);
    for (final index in [1, 0]) {
      final row = await _revealAlbumTrack(tester, index,
        delta: index == 0 ? -120 : 120);
      await tester.tap(row.hitTestable());
      await _frames(tester);
    }
    await tester.tap(find.text('添加到歌单').hitTestable());
    await _frames(tester);
    expect(find.text('添加歌曲到'), findsOneWidget);
    await tester.tap(find.text('多选目标').hitTestable());
    await _frames(tester);
    expect(h.container.read(localPlaylistsProvider.notifier).byId(target.id)!.tracks.map((track) => track.musicInfo?.id),
      ['wy_0', 'wy_1']);
    expect(h.player.played, isEmpty);
    await _finishToast(tester);
  });

}

const _album = AlbumInfo(id: 'record', source: MusicSource.wy, name: '发行专辑', artistName: '艺人');
final _albumVersions = [
  for (final id in ['record', 'record-version']) AlbumInfo(id: id,
    source: MusicSource.wy, name: '发行专辑', artistName: '艺人', songCount: 44,
    publishTime: DateTime.utc(2025, 9, 5)),
];
MusicInfo _song(int index) => MusicInfo.fromJson({
  'id': 'wy_$index', 'name': '原曲 $index', 'singer': '艺人', 'source': 'wy',
  'meta': {'songId': '$index'},
});

final _candidate = MusicInfo.fromJson({
  'id': 'wy_candidate', 'name': '可选版本', 'singer': '艺人', 'source': 'wy',
  'meta': {'songId': 'candidate'},
});

class _Api extends MusicApi {
  _Api({this.songsFail = false, this.catalog = 'data', this.incomplete = false});
  @override
  Future<AlbumPage> searchAlbums({required String keyword, required MusicSource source,
    int page = 1, int limit = 30}) async => AlbumPage(
      albums: [_album], offset: (page - 1) * limit, limit: limit, hasMore: false, total: 1);
  final bool incomplete;
  final bool songsFail;
  String catalog;
  @override
  Future<SearchResponse> searchArtists({required String keyword, required MusicSource source,
    int page = 1, int limit = 30}) async => SearchResponse(
      list: const [], artists: const [], source: source, page: page, limit: limit,
      total: 0, allPage: 0);
  @override
  Future<SearchResponse> searchMusic({required String keyword, required MusicSource source,
    int page = 1, int limit = 30}) async => SearchResponse(
      list: [_candidate], source: source, page: page, limit: limit, total: 1, allPage: 1);
  @override
  Future<List<String>> searchTip({required String keyword, required MusicSource source,
    int limit = 8}) async => [];
  final catalogRequests = <String>[];
  final albumRequests = <String>[];
  late final full = PlaylistInfo(id: 'record', source: MusicSource.wy, name: '发行专辑',
    tracks: List.generate(65, _song), trackCount: incomplete ? 70 : 65, hasMoreTracks: incomplete);
  @override
  Future<PlaylistInfo> albumDetail({required String albumId, required MusicSource source}) async {
    albumRequests.add('${source.code}:$albumId');
    return full;
  }
  @override
  Future<ArtistTrackPage> artistSongs({required String artistId, required MusicSource source,
    required int offset, required int limit}) async {
    if (songsFail) throw StateError('offline songs');
    return ArtistTrackPage(offset: offset, total: 1, artistName: '艺人', tracks: [_song(0)]);
  }
  @override
  Future<AlbumPage> artistAlbums({required String artistId, required MusicSource source,
    int offset = 0, int limit = 30}) async {
    catalogRequests.add('${source.code}:$artistId:$offset');
    if (catalog == 'error') throw StateError('offline albums');
    if (catalog == 'unsupported') throw UnsupportedError('此平台不支持歌手专辑');
    if (catalog == 'versions' || catalog == 'paged-versions') {
      return AlbumPage(albums: catalog == 'versions' ? _albumVersions : offset == 0
        ? [_albumVersions.first]
        : [..._albumVersions, const AlbumInfo(id: 'record-short',
          source: MusicSource.wy, name: '发行专辑', artistName: '艺人', songCount: 9)],
        offset: offset, limit: limit,
        hasMore: catalog == 'paged-versions' && offset == 0);
    }
    return AlbumPage(albums: catalog == 'empty' ? [] : [offset == 0 ? _album :
      const AlbumInfo(id: 'record2', source: MusicSource.wy, name: '第二张专辑', artistName: '艺人')],
      offset: offset, limit: limit, hasMore: catalog == 'paged' && offset == 0);
  }
}

class _Player extends PlayerController {
  _Player(super.ref);
  final played = <DownloadHistoryEntry>[];
  final queues = <List<DownloadHistoryEntry>>[];
  @override
  Future<void> playFromPlaylistQueue(DownloadHistoryEntry entry, List<DownloadHistoryEntry> songs) async {
    played.add(entry);
    queues.add(List.of(songs));
  }
}

class _Harness {
  _Harness(this.router, this.container, this.api, this.player);
  final GoRouter router;
  final ProviderContainer container;
  final _Api api;
  final _Player player;
  String get location => router.routeInformationProvider.value.uri.path;
}

Future<_Harness> _pump(WidgetTester tester, String location, {bool songsFail = false,
  String catalog = 'data'}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final handler = PlayerAudioHandler();
  final api = _Api(songsFail: songsFail, catalog: catalog);
  late _Player player;
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    musicApiProvider.overrideWithValue(api),
    playerAudioHandlerProvider.overrideWithValue(handler),
    playerControllerProvider.overrideWith((ref) => player = _Player(ref)),
    downloadCapabilitiesProvider.overrideWithValue(const AsyncData(DownloadCapabilities(
      sources: {MusicSource.wy: [Quality.k320]}, availableSources: [MusicSource.wy],
    ))),
  ]);
  final router = createAppRouter(initialLocation: location);
  addTearDown(() {router.dispose(); container.dispose(); unawaited(handler.disposeHandler());});
  await tester.pumpWidget(UncontrolledProviderScope(container: container,
    child: MaterialApp.router(routerConfig: router, theme: ThemeData(platform: TargetPlatform.iOS))));
  await _frames(tester);
  // The player is lazily created by the shell.
  container.read(playerControllerProvider);
  return _Harness(router, container, api, player);
}
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {await tester.pump(const Duration(milliseconds: 100));}
}
Future<void> _albums(WidgetTester tester) async {
  final segment = find.byKey(const ValueKey('artist-content-albums'));
  await tester.ensureVisible(segment);
  await tester.tap(segment);
  await _frames(tester);
}
Future<void> _selectAll(WidgetTester tester) async {
  final batch = find.byTooltip('批量操作');
  await tester.ensureVisible(batch);
  await tester.tap(batch);
  await _frames(tester);
  await tester.tap(find.byTooltip('全选'));
  await _frames(tester);
}

Future<void> _slideFirst(WidgetTester tester) async {
  final row = find.byKey(const ValueKey('album-track-wy:wy_0'));
  await tester.ensureVisible(row);
  await tester.drag(row, const Offset(-220, 0));
  await _frames(tester);
}
Future<void> _openMatch(WidgetTester tester) async {
  await _slideFirst(tester);
  await tester.tap(find.text('更换匹配').hitTestable());
  await _frames(tester);
}

Future<Finder> _revealAlbumTrack(WidgetTester tester, int index, {required double delta}) async {
  final row = find.byKey(ValueKey('album-track-wy:wy_$index'));
  final scrollable = find.descendant(
    of: find.byType(OnlinePlaylistDetailPage),
    matching: find.byType(Scrollable),
  ).first;
  // ensureVisible cannot locate a sliver row which has not been built yet.
  await tester.scrollUntilVisible(row, delta, scrollable: scrollable);
  await tester.pumpAndSettle();
  // Align immediately: awaiting a timed scroll would stall the test's fake clock.
  await Scrollable.ensureVisible(tester.element(row), alignment: 0.5);
  await tester.pumpAndSettle();
  expect(row.hitTestable(), findsOneWidget);
  return row;
}

Future<void> _finishToast(WidgetTester tester) async {
  // Use the real 3-second toast lifecycle, including its removal animation.
  await tester.pump(const Duration(seconds: 4));
  await _frames(tester);
  expect(find.byKey(const ValueKey('app-toast-capsule')), findsNothing);
}
