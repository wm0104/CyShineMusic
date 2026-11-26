import 'dart:convert';

import '../models/album_info.dart';
import '../models/enums.dart';
import '../models/music_info.dart';
import '../models/playlist_info.dart';
import '../ui/cover_image_source.dart';
import 'internal/format.dart';
import 'internal/sdk_http.dart';
import 'leaderboard_sdk.dart';
import 'playlist_adapters/kw_playlist_adapter.dart';
import 'playlist_sdk.dart';

/// Public metadata only. No playback URL resolver or source scripts involved.
class AlbumSdk {
  static const Set<MusicSource> sources = {
    MusicSource.wy, MusicSource.tx, MusicSource.kw,
  };

  static Future<AlbumPage> searchAlbums({
    required String keyword,
    required MusicSource source,
    int page = 1,
    int limit = 30,
    SdkJsonLoader loadJson = SdkHttp.getJson,
  }) async {
    _validate(source, (page - 1) * limit, limit);
    final offset = (page - 1) * limit;
    if (source == MusicSource.wy) {
      final body = await loadJson(Uri.https('music.163.com', '/api/search/get', {
        's': keyword, 'type': '10', 'offset': '$offset', 'limit': '$limit',
      }).toString());
      final data = _response(body, 200)['result'];
      if (data is! Map) throw const FormatException('网易云专辑搜索响应不完整');
      final total = _count(data['albumCount']);
      final rows = _rows(data['albums'], allowEmpty: total == 0);
      return _page(rows, source, offset, limit, total: total);
    }
    if (source == MusicSource.tx) {
      final body = await loadJson(Uri.https('c.y.qq.com', '/soso/fcgi-bin/client_search_cp', {
        't': '8', 'format': 'json', 'w': keyword, 'p': '$page', 'n': '$limit',
      }).toString());
      final data = _response(body, 0)['data'];
      final albums = data is Map ? data['album'] : null;
      if (albums is! Map) throw const FormatException('QQ 专辑搜索响应不完整');
      final total = _count(albums['totalnum']);
      return _page(_rows(albums['list'], allowEmpty: total == 0), source, offset, limit, total: total);
    }
    final data = await _kw('/api/www/search/searchAlbumBykeyWord', {
      'key': keyword, 'pn': '$page', 'rn': '$limit',
    }, loadJson);
    final total = _count(data['total']);
    return _page(_rows(data['albumList'], allowEmpty: total == 0), source, offset, limit, total: total);
  }

  static Future<AlbumPage> artistAlbums({
    required String artistId,
    required MusicSource source,
    int offset = 0,
    int limit = 30,
    SdkJsonLoader loadJson = SdkHttp.getJson,
  }) async {
    _validate(source, offset, limit);
    _id(artistId);
    if (source == MusicSource.wy) {
      final body = _response(await loadJson(Uri.https('music.163.com', '/api/artist/albums/${Uri.encodeComponent(artistId)}', {
        'offset': '$offset', 'limit': '$limit',
      }).toString()), 200);
      final rows = _rows(body['hotAlbums']);
      if (body['more'] is! bool) throw const FormatException('网易云专辑分页标记缺失');
      return _page(rows, source, offset, limit, more: body['more'] as bool);
    }
    if (source == MusicSource.tx) {
      final data = await _qq('music.musichallAlbum.AlbumListServer', 'GetAlbumList', {
        'singerMid': artistId, 'begin': offset, 'num': limit, 'order': 1,
      }, loadJson);
      if (data['singerMid'] != artistId) throw const FormatException('QQ 歌手标识不一致');
      final total = _count(data['total']);
      return _page(_rows(data['albumList'], allowEmpty: total == 0), source, offset, limit, total: total);
    }
    final data = await _kw('/api/www/artist/artistAlbum', {
      'artistid': artistId, 'pn': '${offset ~/ limit + 1}', 'rn': '$limit',
    }, loadJson);
    final total = _count(data['total']);
    final rows = _rows(data['albumList'], allowEmpty: total == 0).skip(offset % limit).toList();
    return _page(rows, source, offset, limit, total: total);
  }

  static Future<PlaylistInfo> albumDetail({
    required String albumId,
    required MusicSource source,
    SdkJsonLoader loadJson = SdkHttp.getJson,
  }) async {
    _validate(source, 0, 100);
    _id(albumId);
    if (source == MusicSource.wy) {
      final body = _response(await loadJson(Uri.https('music.163.com', '/api/album/${Uri.encodeComponent(albumId)}').toString()), 200);
      final album = body['album'];
      if (album is! Map || album['id']?.toString() != albumId) throw const FormatException('网易云专辑标识不一致');
      final rows = _rows(album['songs']);
      final total = _count(album['size']);
      if (total == null || rows.length != total) throw const FormatException('网易云专辑曲目不完整');
      final tracks = [for (final row in rows) _track(PlaylistSdk.parseWySong(row))];
      final info = _album(album, source);
      return _detail(info, tracks);
    }

    // Fetch every metadata page. A short/empty/repeated page is not completion
    // unless the server's declared total is reached.
    final rows = <Map>[];
    final seen = <String>{};
    AlbumInfo? info;
    int? total;
    for (var begin = 0; ; begin += 100) {
      late Map data;
      late List<Map> pageRows;
      if (source == MusicSource.tx) {
        data = await _qq('music.musichallAlbum.AlbumSongList', 'GetAlbumSongList', {
          'albumMid': albumId, 'begin': begin, 'num': 100, 'order': 2,
        }, loadJson);
        if (data['albumMid'] != albumId) throw const FormatException('QQ 专辑标识不一致');
        final count = _count(data['totalNum']);
        if (count == null || (total != null && count != total)) throw const FormatException('QQ 专辑曲目数量变化');
        total = count;
        pageRows = [for (final row in _rows(data['songList'], allowEmpty: total == 0))
          if (row['songInfo'] is Map) row['songInfo'] as Map else throw const FormatException('QQ 专辑曲目响应不完整')];
        if (info == null && pageRows.isNotEmpty) {
          final album = pageRows.first['album'];
          if (album is! Map || album['mid'] != albumId) throw const FormatException('QQ 专辑曲目标识不一致');
          info = AlbumInfo(id: albumId, source: source, name: decodeName(album['name']), artistName: _qqArtists(pageRows.first['singer']), coverUrl: _qqCover(albumId), songCount: total);
        }
      } else {
        data = await _kw('/api/www/album/albumInfo', {'albumId': albumId, 'pn': '${begin ~/ 100 + 1}', 'rn': '100'}, loadJson);
        if (data['albumid']?.toString() != albumId) throw const FormatException('酷我专辑标识不一致');
        final count = _count(data['total']);
        if (count == null || (total != null && count != total)) throw const FormatException('酷我专辑曲目数量变化');
        total = count;
        pageRows = _rows(data['musicList'], allowEmpty: total == 0);
        info ??= _album(data, source);
      }
      for (final row in pageRows) {
        final id = row[source == MusicSource.tx ? 'mid' : 'rid']?.toString();
        if (id == null || !seen.add(id)) throw const FormatException('专辑曲目分页重复或标识缺失');
        final album = row['album'];
        final rowAlbum = source == MusicSource.tx
            ? (album is Map ? album['mid'] : null)
            : row['albumid'];
        if (rowAlbum?.toString() != albumId) throw const FormatException('专辑曲目来自其它专辑');
      }
      rows.addAll(pageRows);
      if (rows.length == total) break;
      if (rows.length > total || pageRows.length != 100) throw const FormatException('专辑完整曲目尚未返回');
    }
    // Sort only unambiguous positive positions; otherwise retain server order.
    final positions = [for (final row in rows) _count(row['track'])];
    if (source == MusicSource.kw &&
        positions.every((position) => position != null && position > 0) &&
        positions.toSet().length == rows.length) {
      rows.sort((a, b) => _count(a['track'])!.compareTo(_count(b['track'])!));
    }
    final tracks = [for (final row in rows)
      _track(source == MusicSource.tx ? LeaderboardSdk.parseTxTrack(row) : KwPlaylistAdapter.parseTrack({...row, 'id': row['rid']}))];
    return _detail(info ?? AlbumInfo(id: albumId, source: source, name: albumId, artistName: '', songCount: total), tracks);
  }

  static AlbumPage _page(List<Map> rows, MusicSource source, int offset, int limit, {int? total, bool? more}) {
    if (total != null && offset < total && rows.isEmpty) throw const FormatException('专辑目录分页不完整');
    return AlbumPage(albums: [for (final row in rows) _album(row, source)], offset: offset, limit: limit, total: total, hasMore: more ?? (total != null ? offset + rows.length < total : rows.length == limit));
  }

  static AlbumInfo _album(Map row, MusicSource source) {
    final id = row[source == MusicSource.wy ? 'id' : source == MusicSource.tx ? (row.containsKey('albumMID') ? 'albumMID' : 'albumMid') : 'albumid']?.toString() ?? '';
    final name = decodeName(row[source == MusicSource.wy ? 'name' : source == MusicSource.tx ? 'albumName' : 'album']);
    if (id.isEmpty || name.isEmpty) throw const FormatException('专辑身份或名称缺失');
    final artist = row['artist'];
    final wyArtists = row['artists'];
    final artistName = source == MusicSource.wy
        ? wyArtists is List && wyArtists.isNotEmpty
            ? wyArtists.whereType<Map>().map((a) => decodeName(a['name'])).join('、')
            : artist is Map ? decodeName(artist['name']) : ''
        : decodeName(row[source == MusicSource.tx ? 'singerName' : 'artist']);
    final published = row[source == MusicSource.wy ? 'publishTime' : source == MusicSource.tx ? (row.containsKey('publicTime') ? 'publicTime' : 'publishDate') : 'releaseDate'];
    final publishTime = source == MusicSource.wy && published is num
        ? DateTime.fromMillisecondsSinceEpoch(published.toInt(), isUtc: true)
        : DateTime.tryParse(published?.toString() ?? '');
    return AlbumInfo(
      id: id, source: source, name: name, artistName: artistName,
      coverUrl: source == MusicSource.tx ? _qqCover(id) : CoverImageSource.normalizeUrl(row[source == MusicSource.wy ? 'picUrl' : 'pic']?.toString()),
      songCount: _count(row[source == MusicSource.wy ? 'size' : source == MusicSource.tx ? 'song_count' : 'total']),
      publishTime: publishTime,
    );
  }

  static String _qqArtists(dynamic rows) => rows is List ? rows.whereType<Map>().map((r) => decodeName(r['name'])).join('、') : '';
  static String _qqCover(String id) => 'https://y.gtimg.cn/music/photo_new/T002R500x500M000$id.jpg';
  static PlaylistInfo _detail(AlbumInfo info, List<MusicInfo> tracks) => PlaylistInfo(
    id: info.id, source: info.source, name: info.name, creator: info.artistName,
    coverUrl: info.coverUrl, tracks: List<MusicInfo>.unmodifiable(tracks), trackCount: tracks.length, hasMoreTracks: false,
  );
  static MusicInfo _track(MusicInfo? track) => track ?? (throw const FormatException('专辑曲目无法完整解析'));
  static int? _count(Object? value) {
    final result = int.tryParse(value?.toString() ?? '');
    return result != null && result >= 0 ? result : null;
  }
  static List<Map> _rows(dynamic value, {bool allowEmpty = false}) {
    if (value == null && allowEmpty) return [];
    if (value is! List || value.any((r) => r is! Map)) throw const FormatException('专辑列表响应无效');
    return value.cast<Map>();
  }
  static Map _response(dynamic body, int code) {
    if (body is! Map || body['code'] != code) throw const FormatException('专辑元数据请求失败');
    return body;
  }
  static void _validate(MusicSource source, int offset, int limit) {
    if (!sources.contains(source)) throw UnsupportedError('当前平台不支持专辑');
    if (offset < 0 || limit <= 0) throw ArgumentError('专辑分页参数无效');
  }
  static void _id(String id) {
    if (id.trim().isEmpty) throw ArgumentError('专辑或歌手标识为空');
  }
  static Future<Map> _kw(String path, Map<String, String> query, SdkJsonLoader load) async {
    final body = _response(await load(Uri.https('wapi.kuwo.cn', path, query).toString()), 200);
    final data = body['data'];
    if (data is! Map) throw const FormatException('酷我专辑响应不完整');
    return data;
  }
  static Future<Map> _qq(String module, String method, Map<String, Object> param, SdkJsonLoader load) async {
    final uri = Uri.https('u.y.qq.com', '/cgi-bin/musicu.fcg', {
      'format': 'json', 'data': jsonEncode({'req': {'module': module, 'method': method, 'param': param}}),
    });
    final body = _response(await load(uri.toString()), 0);
    final reply = _response(body['req'], 0);
    final data = reply['data'];
    if (data is! Map) throw const FormatException('QQ 专辑响应不完整');
    return data;
  }
}
