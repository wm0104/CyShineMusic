import 'dart:async';

import 'package:cy_shine_music/core/api/music_api.dart';
import 'package:cy_shine_music/core/models/album_info.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/search_response.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/search/search_controller.dart';
import 'package:cy_shine_music/features/search/widgets/source_filter_chips.dart';
import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({
    'enabled_search_source_codes': ['wy', 'tx'],
    'network_adapter_mode': 'io',
  }));

  test('search categories retain songs then artists and add albums last', () {
    expect(SearchCategory.values.map((value) => value.label), ['歌曲', '歌手', '专辑']);
    expect(const SearchState().category, SearchCategory.songs);
  });

  testWidgets('discovery category chips keep songs artists albums on a small screen', (tester) async {
    final container = await _container(_AlbumSearchApi());
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: Center(
        child: SizedBox(width: 162, child: SearchCategoryChips()),
      ))),
    ));
    expect(find.text('歌曲'), findsOneWidget);
    expect(find.text('歌手'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(tester.getCenter(find.text('歌曲')).dx,
        lessThan(tester.getCenter(find.text('歌手')).dx));
    expect(tester.getCenter(find.text('歌手')).dx,
        lessThan(tester.getCenter(find.text('专辑')).dx));
    await tester.tap(find.text('专辑'));
    await tester.pumpAndSettle();
    expect(container.read(searchControllerProvider).category, SearchCategory.albums);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('album search returns album identities and caches a complete page', () async {
    final api = _AlbumSearchApi();
    final container = await _container(api);
    final controller = container.read(searchControllerProvider.notifier);
    controller.setCategory(SearchCategory.albums);
    await controller.search(keyword: 'Album', source: MusicSource.wy);
    final state = container.read(searchControllerProvider);
    expect(state.category, SearchCategory.albums);
    expect(state.resultCount, 1);
    expect(state.response!.albums.single.id, 'album-a');
    expect(state.response!.list, isEmpty);
    expect(state.response!.hasNextPage, isFalse);
    await controller.search(keyword: 'Album', source: MusicSource.wy);
    expect(api.albumCalls, 1);
    expect(api.songCalls, 0);
  });

  test('album paging keeps the query and does not claim an unknown total', () async {
    final api = _AlbumSearchApi(unknownTotal: true);
    final container = await _container(api);
    final controller = container.read(searchControllerProvider.notifier);
    controller.setCategory(SearchCategory.albums);
    await controller.search(keyword: 'Album', source: MusicSource.wy);
    final first = container.read(searchControllerProvider).response!;
    expect(first.totalIsExact, isFalse);
    expect(first.hasNextPage, isTrue);
    await controller.search(keyword: 'Album', source: MusicSource.wy, page: 2);
    expect(api.albumPages, [1, 2]);
    expect(container.read(searchControllerProvider).page, 2);
    expect(container.read(searchControllerProvider).keyword, 'Album');
  });

  test('merged platform totals are not a fabricated aggregate page count', () async {
    final api = _AlbumSearchApi(total: 300, more: true);
    final container = await _container(api);
    final controller = container.read(searchControllerProvider.notifier);
    controller.setCategory(SearchCategory.albums);
    await controller.search(keyword: 'Album', source: MusicSource.all);
    final response = container.read(searchControllerProvider).response!;
    expect(response.total, 300);
    expect(response.totalIsExact, isTrue);
    expect(response.allPage, 0);
    expect(response.hasNextPage, isTrue);
  });

  test('partial album failures are not cached as complete success', () async {
    final api = _AlbumSearchApi(partial: true);
    final container = await _container(api);
    final controller = container.read(searchControllerProvider.notifier);
    controller.setCategory(SearchCategory.albums);
    await controller.search(keyword: 'Album', source: MusicSource.wy);
    expect(container.read(searchControllerProvider).response!.hasFailedSources, isTrue);
    await controller.search(keyword: 'Album', source: MusicSource.wy);
    expect(api.albumCalls, 2);
  });

  test('an album request cannot replace results after returning to songs', () async {
    final api = _AlbumSearchApi(pending: true);
    final container = await _container(api);
    final controller = container.read(searchControllerProvider.notifier);
    controller.setCategory(SearchCategory.albums);
    final pending = controller.search(keyword: 'Album', source: MusicSource.wy);
    controller.setCategory(SearchCategory.songs);
    await container.pump();
    api.completer.complete(api.page());
    await pending;
    await container.pump();
    final state = container.read(searchControllerProvider);
    expect(state.category, SearchCategory.songs);
    expect(state.response!.albums, isEmpty);
    expect(api.songCalls, 1);
  });
}

Future<ProviderContainer> _container(_AlbumSearchApi api) async {
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    musicApiProvider.overrideWithValue(api),
  ]);
  addTearDown(container.dispose);
  return container;
}

class _AlbumSearchApi extends MusicApi {
  _AlbumSearchApi({this.unknownTotal = false, this.partial = false,
    this.pending = false, this.total = 1, this.more = false});
  final int total;
  final bool more;
  final bool unknownTotal;
  final bool partial;
  final bool pending;
  final completer = Completer<AlbumPage>();
  int albumCalls = 0;
  int songCalls = 0;
  final albumPages = <int>[];

  AlbumPage page() => AlbumPage(
    albums: const [AlbumInfo(id: 'album-a', source: MusicSource.wy,
      name: 'Album', artistName: 'Singer', coverUrl: 'https://example.test/album.jpg')],
    offset: 0, limit: 30, total: unknownTotal ? null : total,
    hasMore: unknownTotal || more, hasFailedSources: partial,
  );

  @override
  Future<AlbumPage> searchAlbums({required String keyword,
    required MusicSource source, int page = 1, int limit = 30}) async {
    albumCalls++;
    albumPages.add(page);
    return pending ? completer.future : this.page();
  }

  @override
  Future<SearchResponse> searchMusic({required String keyword,
    required MusicSource source, int page = 1, int limit = 30}) async {
    songCalls++;
    return SearchResponse(list: const [], page: page, limit: limit,
      allPage: 1, total: 0, source: source);
  }
}
