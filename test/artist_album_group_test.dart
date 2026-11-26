import 'package:cy_shine_music/core/models/album_info.dart';
import 'package:cy_shine_music/core/models/artist_album_group.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:flutter_test/flutter_test.dart';

AlbumInfo _album(
  String id,
  String name,
  int? count, {
  MusicSource source = MusicSource.wy,
}) => AlbumInfo(
  id: id,
  source: source,
  name: name,
  artistName: 'Artist',
  songCount: count,
);

void main() {
  test('same normalized title and positive count group without losing IDs', () {
    final first = _album('284075851', 'SWAG II', 44);
    final second = _album('285096821', '  swag   II  ', 44);
    final groups = groupArtistAlbums([first, second]);
    expect(groups, hasLength(1));
    expect(groups.single.representative, same(first));
    expect(groups.single.variants, [first, second]);
    expect(() => groups.single.variants.clear(), throwsUnsupportedError);
  });

  test('different sizes and version titles remain separate releases', () {
    final albums = [
      _album('full', 'Hurry Up Tomorrow', 22),
      _album('short', 'Hurry Up Tomorrow', 9),
      _album('remix-three', 'Timeless (Remix)', 3),
      _album('remix-one', 'Timeless (Remix)', 1),
      _album('deluxe', 'Hurry Up Tomorrow (Deluxe)', 22),
    ];
    expect(
      groupArtistAlbums(albums).map((group) => group.representative),
      albums,
    );
  });

  test('unknown and zero sizes do not establish a version group', () {
    final albums = [
      _album('unknown-a', 'Album', null),
      _album('unknown-b', 'Album', null),
      _album('empty-a', 'Album', 0),
      _album('empty-b', 'Album', 0),
      _album('blank-a', ' ', 3),
      _album('blank-b', ' ', 3),
    ];
    expect(groupArtistAlbums(albums), hasLength(albums.length));
  });

  test('source identity and first appearance order survive page overlaps', () {
    final a = _album('a', 'Album', 3);
    final other = _album('other', 'Other', 3);
    final b = _album('b', 'Album', 3);
    final qq = _album('a', 'Album', 3, source: MusicSource.tx);
    final groups = groupArtistAlbums([a, other, a, b, qq, b]);
    expect(groups.map((group) => group.representative), [a, other, qq]);
    expect(groups.first.variants, [a, b]);
    expect(groups.last.variants, [qq]);
  });
}
