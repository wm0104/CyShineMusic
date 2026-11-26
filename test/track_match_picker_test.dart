import 'package:cy_shine_music/core/api/music_api.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/models/search_response.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/playlists/playlist_models.dart';
import 'package:cy_shine_music/features/playlists/spotify_track_match_picker.dart';
import 'package:cy_shine_music/features/search/search_page.dart';
import 'package:cy_shine_music/features/search/track_match_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final candidate = MusicInfo.fromJson({
  'id': 'tx_candidate', 'name': '候选', 'singer': '歌手', 'source': 'tx',
  'meta': {'songId': 'candidateMID', 'albumName': 'A', 'qualitys': []},
});

class PickerApi extends MusicApi {
  @override
  Future<SearchResponse> searchMusic({required String keyword, required MusicSource source, int page = 1, int limit = 30}) async => SearchResponse(list: [candidate], page: page, limit: limit, allPage: 1, total: 1, source: source);

  @override
  Future<List<String>> searchTip({required String keyword, required MusicSource source, int limit = 8}) async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('generic match picker uses existing iOS route and returns selection without Spotify metadata', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    MusicInfo? selected;
    await tester.pumpWidget(ProviderScope(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      musicApiProvider.overrideWithValue(PickerApi()),
    ], child: MaterialApp(theme: ThemeData(platform: TargetPlatform.iOS), home: Builder(builder: (context) => TextButton(
      onPressed: () async { selected = await showTrackMatchPicker(context, title: '原曲', artist: '歌手', initialSource: MusicSource.tx); },
      child: const Text('打开匹配'),
    )))));
    await tester.tap(find.text('打开匹配'));
    await tester.pumpAndSettle();
    final page = tester.widget<SearchPage>(find.byType(SearchPage));
    expect(page.initialKeyword, '原曲 歌手');
    expect(page.initialSource, MusicSource.tx);
    expect(ModalRoute.of(tester.element(find.byType(SearchPage))), isA<CupertinoPageRoute<MusicInfo>>());
    expect(find.byTooltip('添加到歌单'), findsNothing);
    await tester.tap(find.text('候选'));
    await tester.pumpAndSettle();
    expect(selected, same(candidate));
    expect(find.text('打开匹配'), findsOneWidget);
  });

  testWidgets('Spotify wrapper retains matched platform default and cancellation returns null', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    MusicInfo? selected = candidate;
    final track = PlaylistTrack.fromSpotify(const SpotifyTrackMetadata(uri: 'spotify:track:o', title: '原曲', artist: '歌手', occurrence: 0), candidate);
    await tester.pumpWidget(ProviderScope(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      musicApiProvider.overrideWithValue(PickerApi()),
    ], child: MaterialApp(home: Builder(builder: (context) => TextButton(
      onPressed: () async { selected = await pickSpotifyTrackMatch(context, track); }, child: const Text('打开匹配'),
    )))));
    await tester.tap(find.text('打开匹配'));
    await tester.pumpAndSettle();
    expect(tester.widget<SearchPage>(find.byType(SearchPage)).initialSource, MusicSource.tx);
    Navigator.of(tester.element(find.byType(SearchPage))).pop();
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(track.musicInfo?.id, candidate.id);
  });
}
