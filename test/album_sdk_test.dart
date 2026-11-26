import 'dart:convert';

import 'package:cy_shine_music/core/api/music_api.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/sdk/album_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('album capabilities reject unsupported instead of returning empty', () async {
    expect(MusicApi.albumSources, {MusicSource.wy, MusicSource.tx, MusicSource.kw});
    await expectLater(MusicApi().albumDetail(albumId: '1', source: MusicSource.kg), throwsUnsupportedError);
    await expectLater(MusicApi().artistAlbums(artistId: '1', source: MusicSource.mg), throwsUnsupportedError);
  });

  test('WY artist catalog uses exact ID and server more flag, not hot songs', () async {
    final page = await AlbumSdk.artistAlbums(artistId: '6452', source: MusicSource.wy, offset: 2, limit: 2,
      loadJson: (raw, {headers}) async {
        final uri = Uri.parse(raw);
        expect(uri.path, '/api/artist/albums/6452');
        expect(uri.queryParameters, {'offset': '2', 'limit': '2'});
        return {'code': 200, 'hotAlbums': [{'id': 7, 'name': 'Album', 'artist': {'name': 'Artist'}, 'size': 5}], 'more': true};
      });
    expect(page.albums.single.id, '7');
    expect(page.albums.single.songCount, 5);
    expect(page.total, isNull);
    expect(page.hasMore, isTrue);
  });

  test('WY album never truncates at 40 or hides malformed missing tracks', () async {
    final rows = List.generate(53, (i) => {'id': i + 1, 'name': 'Song $i', 'position': i + 1});
    final album = await AlbumSdk.albumDetail(albumId: '7', source: MusicSource.wy,
      loadJson: (url, {headers}) async => {'code': 200, 'album': {'id': 7, 'name': 'Full', 'size': 53, 'songs': rows}});
    expect(album.tracks.length, 53);
    expect(album.tracks.last.meta.songId, 53);
    expect(album.tracks.last.meta.albumId, '7');
    expect(album.tracks.last.albumName, 'Full');
    expect(album.hasMoreTracks, isFalse);
    await expectLater(AlbumSdk.albumDetail(albumId: '7', source: MusicSource.wy,
      loadJson: (url, {headers}) async => {'code': 200, 'album': {'id': 7, 'size': 54, 'songs': rows}}), throwsFormatException);
  });

  test('WY keeps a track’s own album metadata on a compilation', () async {
    final album = await AlbumSdk.albumDetail(albumId: '7', source: MusicSource.wy,
      loadJson: (url, {headers}) async => {
        'code': 200, 'album': {'id': 7, 'name': 'Compilation', 'size': 2, 'songs': [
          {'id': 1, 'name': 'Song A', 'album': {'name': 'Original'}},
          {'id': 2, 'name': 'Song B', 'al': {'name': 'Original', 'id': 12}},
        ]},
      });
    expect(album.tracks.first.albumName, 'Original');
    expect(album.tracks.first.meta.albumId, isNull);
    expect(album.tracks.last.meta.albumId, 12);
  });

  test('QQ retains MID and loads all pages in album order', () async {
    final starts = <int>[];
    final album = await AlbumSdk.albumDetail(albumId: 'mid-not-number', source: MusicSource.tx,
      loadJson: (url, {headers}) async {
        // The public request is inspectable; no playback resolver involved.
        final data = (jsonDecode(Uri.parse(url).queryParameters['data']!) as Map)['req'] as Map;
        final param = data['param'] as Map;
        expect(param['albumMid'], 'mid-not-number');
        final begin = param['begin'] as int;
        starts.add(begin);
        final end = (begin + 100).clamp(0, 103);
        return {'code': 0, 'req': {'code': 0, 'data': {'albumMid': 'mid-not-number', 'totalNum': 103,
          'songList': [for (var i = begin; i < end; i++) {'songInfo': {'id': i, 'mid': 's$i', 'name': 'Track $i', 'index_album': i + 1, 'file': {'media_mid': 'media$i'}, 'album': {'mid': 'mid-not-number', 'name': 'Album'}}}]}}};
      });
    expect(starts, [0, 100]);
    expect(album.tracks.length, 103);
    expect(album.tracks.last.meta.songId, 's102');
  });

  test('KW loads every page and honors track number rather than popularity order', () async {
    final pages = <String>[];
    final album = await AlbumSdk.albumDetail(albumId: '1293', source: MusicSource.kw,
      loadJson: (url, {headers}) async {
        final query = Uri.parse(url).queryParameters;
        expect(query['albumId'], '1293');
        final page = int.parse(query['pn']!);
        pages.add(query['pn']!);
        final start = (page - 1) * 100;
        return {'code': 200, 'data': {'albumid': 1293, 'album': 'A', 'total': 102,
          'musicList': [for (var i = start; i < (start + 100).clamp(0, 102); i++)
            {'rid': i + 1, 'albumid': 1293, 'name': 'Track $i', 'track': 102 - i}]}};
      });
    expect(pages, ['1', '2']);
    expect(album.tracks.length, 102);
    expect(album.tracks.first.meta.songId, 102);
    expect(album.tracks.first.albumName, 'A');
    expect(album.tracks.first.meta.albumId, 1293);
    expect(album.tracks.last.meta.songId, 1);
    expect(album.hasMoreTracks, isFalse);
  });

  test('KW ambiguous zero positions retain server order', () async {
    final album = await AlbumSdk.albumDetail(albumId: '1', source: MusicSource.kw,
      loadJson: (url, {headers}) async => {'code': 200, 'data': {'albumid': 1, 'album': 'A', 'total': 2,
        'musicList': [for (final id in [2, 1]) {'rid': id, 'albumid': 1, 'name': '$id', 'track': 0}]}});
    expect(album.tracks.map((track) => track.meta.songId), [2, 1]);
  });

  test('QQ artist catalog accepts only exact MID and exposes server total', () async {
    final page = await AlbumSdk.artistAlbums(artistId: 'MID', source: MusicSource.tx, offset: 30, limit: 30,
      loadJson: (url, {headers}) async {
        final request = (jsonDecode(Uri.parse(url).queryParameters['data']!) as Map)['req'] as Map;
        expect((request['param'] as Map)['singerMid'], 'MID');
        return {'code': 0, 'req': {'code': 0, 'data': {'singerMid': 'MID', 'total': 31,
          'albumList': [{'albumMid': 'albumMID', 'albumName': 'A', 'publishDate': '2003-07-31'}]}}};
      });
    expect(page.total, 31);
    expect(page.hasMore, isFalse);
    expect(page.albums.single.id, 'albumMID');
    expect(page.albums.single.publishTime?.year, 2003);
    expect(page.hasFailedSources, isFalse);
  });

  test('all search with only unsupported enabled platforms does not query them', () async {
    final result = await MusicApi(enabledSearchSources: {MusicSource.kg, MusicSource.mg}).searchAlbums(keyword: 'x', source: MusicSource.all);
    expect(result.albums, isEmpty);
    expect(result.hasFailedSources, isFalse);
    expect(result.total, 0);
  });

  test('short QQ album pages cannot be represented as a complete album', () async {
    await expectLater(AlbumSdk.albumDetail(albumId: 'MID', source: MusicSource.tx,
      loadJson: (url, {headers}) async => {'code': 0, 'req': {'code': 0, 'data': {'albumMid': 'MID', 'totalNum': 41, 'songList': []}}}), throwsFormatException);
  });

  test('request errors remain errors; valid empty catalogs remain empty', () async {
    await expectLater(AlbumSdk.searchAlbums(keyword: 'x', source: MusicSource.wy,
      loadJson: (url, {headers}) async => {'code': 500}), throwsFormatException);
    final empty = await AlbumSdk.searchAlbums(keyword: 'x', source: MusicSource.wy,
      loadJson: (url, {headers}) async => {'code': 200, 'result': {'albumCount': 0}});
    expect(empty.albums, isEmpty);
    expect(empty.hasMore, isFalse);
  });
}
