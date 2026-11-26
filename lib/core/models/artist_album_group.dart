import 'album_info.dart';
import 'enums.dart';

class ArtistAlbumGroup {
  ArtistAlbumGroup(Iterable<AlbumInfo> variants)
    : variants = List<AlbumInfo>.unmodifiable(variants);

  final List<AlbumInfo> variants;
  AlbumInfo get representative => variants.first;
}

/// One artist's catalog only. Group display rows without merging identities.
List<ArtistAlbumGroup> groupArtistAlbums(Iterable<AlbumInfo> albums) {
  final variants = <List<AlbumInfo>>[];
  final indexes = <(MusicSource, String, int), int>{};
  final seen = <(MusicSource, String)>{};
  for (final album in albums) {
    if (!seen.add((album.source, album.id))) continue;
    final name = album.name
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ')
        .toLowerCase();
    final count = album.songCount;
    if (name.isEmpty || count == null || count <= 0) {
      variants.add([album]);
      continue;
    }
    final key = (album.source, name, count);
    final index = indexes[key];
    if (index == null) {
      indexes[key] = variants.length;
      variants.add([album]);
    } else {
      variants[index].add(album);
    }
  }
  return [for (final group in variants) ArtistAlbumGroup(group)];
}
