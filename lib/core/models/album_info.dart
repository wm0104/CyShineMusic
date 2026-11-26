import 'enums.dart';

class AlbumInfo {
  const AlbumInfo({
    required this.id,
    required this.source,
    required this.name,
    required this.artistName,
    this.coverUrl,
    this.songCount,
    this.publishTime,
  });

  final String id;
  final MusicSource source;
  final String name;
  final String artistName;
  final String? coverUrl;
  final int? songCount;
  final DateTime? publishTime;
}

class AlbumPage {
  AlbumPage({
    required List<AlbumInfo> albums,
    required this.offset,
    required this.limit,
    this.total,
    required this.hasMore,
    this.hasFailedSources = false,
  }) : albums = List<AlbumInfo>.unmodifiable(albums);

  final List<AlbumInfo> albums;
  final int offset;
  final int limit;
  final int? total;
  final bool hasMore;
  final bool hasFailedSources;
}
