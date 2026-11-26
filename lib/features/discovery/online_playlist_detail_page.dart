import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/album_info.dart';
import '../../core/models/artist_album_group.dart';
import '../../core/services/download_service.dart';
import '../../core/ui/expressive_download_button.dart';
import '../../core/ui/tight_track_actions.dart';
import '../../theme/app_motion.dart';
import '../search/track_match_picker.dart';
import '../search/widgets/album_result_tile.dart';
import '../search/widgets/source_filter_chips.dart';
import 'album_track_match_store.dart';
import 'widgets/discovery_playlist_cover.dart';

import '../../core/api/music_api.dart';
import '../shell/shell_bottom_area.dart';
import '../../core/models/artist_info.dart';
import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import '../../core/models/online_collection_kind.dart';
import '../../core/models/playlist_info.dart';
import '../../core/models/playlist_summary.dart';
import '../../core/services/app_logger.dart';
import '../../core/storage/settings_store.dart';
import '../../core/ui/app_toast.dart';
import '../../core/ui/app_refresh_indicator.dart';
import '../../core/ui/app_scrollbar.dart';
import '../../core/ui/cover_image_source.dart';
import '../../core/ui/cover_placeholder.dart';
import '../../core/ui/car_display_layout.dart';
import '../downloads/download_history_store.dart';
import '../downloads/download_progress.dart';
import '../music_sources/music_source_action_guard.dart';
import '../player/player_artist_resolver.dart';
import '../player/player_controller.dart';
import '../playlists/playlist_models.dart';
import '../playlists/playlist_browser_sheet.dart';
import '../playlists/playlist_store.dart';
import '../playlists/widgets/immersive_playlist_chrome.dart';
import '../playlists/widgets/playlist_detail_actions.dart';
import '../playlists/widgets/playlist_wide_layout.dart';
import '../search/widgets/quality_picker_sheet.dart';
import '../search/widgets/search_result_tile.dart';
import 'discovery_controller.dart';
import '../shell/shell_navigation.dart';
import '../shell/widgets/toolbar_metrics.dart';

class OnlinePlaylistDetailPage extends ConsumerStatefulWidget {
  const OnlinePlaylistDetailPage({
    super.key,
    required this.source,
    required this.playlistId,
    this.kind = OnlineCollectionKind.playlist,
    this.summary,
    this.onBack,
    this.fromPlayback = false,
  });

  final MusicSource source;
  final String playlistId;
  final OnlineCollectionKind kind;
  final PlaylistSummary? summary;
  final VoidCallback? onBack;
  final bool fromPlayback;

  @override
  ConsumerState<OnlinePlaylistDetailPage> createState() =>
      _OnlinePlaylistDetailPageState();
}

class _OnlinePlaylistDetailPageState
    extends ConsumerState<OnlinePlaylistDetailPage> {
  static const _summaryCacheLimit = 48;

  int _trackLimit = onlinePlaylistDetailInitialTrackLimit;
  PlaylistInfo? _lastPlaylist;
  PlaylistSummary? _summary;
  bool _artistAlbums = false;
  final List<int> _albumOffsets = [0];
  bool _batchMode = false;
  bool _batchSubmitting = false;
  final Set<String> _selectedTracks = {};
  bool _saving = false;
  bool _removingFavorite = false;
  final ScrollController _scrollController = ScrollController();

  OnlinePlaylistIdentity get _identity =>
      (source: widget.source, id: widget.playlistId, kind: widget.kind);

  int get _savedTrackLimit =>
      ref.read(onlinePlaylistTrackLimitCacheProvider)[_identity] ??
      onlinePlaylistDetailInitialTrackLimit;

  OnlinePlaylistKey get _key => OnlinePlaylistKey(
    source: widget.source,
    id: widget.playlistId,
    kind: widget.kind,
    maxTracks: _trackLimit,
  );

  String get _returnLocation => _album && widget.fromPlayback
      ? GoRouterState.of(context).uri.toString() :
      '/discover/${widget.kind.path}/${widget.source.code}/${Uri.encodeComponent(widget.playlistId)}';

  String get _detailLabel => '${widget.kind.label}详情';
  bool get _artist => widget.kind == OnlineCollectionKind.artist;
  bool get _album => widget.kind == OnlineCollectionKind.album;

  String _trackKey(MusicInfo music) => '${music.source.code}:${music.id}';

  MusicInfo _effectiveMusic(MusicInfo original) => !_album ? original :
      ref.read(albumTrackMatchesProvider)[albumTrackMatchKey(
        source: widget.source, albumId: widget.playlistId, original: original,
      )] ?? original;

  List<DownloadHistoryEntry> _queueFor(PlaylistInfo playlist, {Iterable<MusicInfo>? tracks}) =>
      _onlinePlaylistQueue(playlist, widget.kind, tracks: tracks,
        resolve: _album ? _effectiveMusic : null);

  ArtistInfo? get _playerArtist {
    final artist = ref
        .read(playerArtistSelectionProvider)
        ?.resolution
        .singleArtist;
    return artist?.source == widget.source && artist?.id == widget.playlistId
        ? artist
        : null;
  }

  String? _playbackArtistCover(PlaylistInfo? loaded) {
    final artist = _playerArtist;
    final cover = CoverImageSource.normalizeArtistUrl(_summary?.coverUrl) ??
        CoverImageSource.normalizeArtistUrl(artist?.coverUrl) ??
        CoverImageSource.normalizeArtistUrl(loaded?.coverUrl);
    if (cover != null) return cover;
    final name = (_summary?.name ?? artist?.name ?? loaded?.name)?.trim();
    if (name == null || name.isEmpty || name == _detailLabel) return null;
    return ref.watch(artistArtworkProvider((source: widget.source,
      id: widget.playlistId, name: name))).asData?.value;
  }

  void _invalidateDetail({bool retry = false}) {
    if (_artist && _artistAlbums) {
      for (final offset in _albumOffsets) {
        final provider = artistAlbumPageProvider((source: widget.source, id: widget.playlistId, offset: offset));
        if (!retry || ref.read(provider).hasError) ref.invalidate(provider);
      }
      return;
    }
    if (_artist) {
      for (
        int offset = 0;
        offset < _trackLimit;
        offset += onlinePlaylistDetailTrackPageSize
      ) {
        final provider = artistTrackPageProvider((
          source: widget.source,
          id: widget.playlistId,
          offset: offset,
        ));
        if (!retry || ref.read(provider).hasError) ref.invalidate(provider);
      }
    }
    ref.invalidate(onlinePlaylistDetailProvider(_key));
  }

  @override
  void initState() {
    super.initState();
    _trackLimit = _savedTrackLimit;
    _summary =
        widget.summary ??
        ref.read(onlinePlaylistSummaryCacheProvider)[_identity];
    _cacheSummary(_summary);
  }

  @override
  void didUpdateWidget(covariant OnlinePlaylistDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final identityChanged =
        oldWidget.source != widget.source ||
        oldWidget.playlistId != widget.playlistId ||
        oldWidget.kind != widget.kind;
    if (identityChanged) {
      _trackLimit = _savedTrackLimit;
      _lastPlaylist = null;
      _artistAlbums = false;
      _albumOffsets..clear()..add(0);
      _batchMode = false;
      _batchSubmitting = false;
      _selectedTracks.clear();
      _summary =
          widget.summary ??
          ref.read(onlinePlaylistSummaryCacheProvider)[_identity];
      _saving = false;
      _removingFavorite = false;
    } else if (widget.summary != null) {
      _summary = widget.summary;
    }
    _cacheSummary(_summary);
  }

  void _cacheSummary(PlaylistSummary? summary) {
    if (summary == null) return;
    final cache = ref.read(onlinePlaylistSummaryCacheProvider);
    if (cache.length >= _summaryCacheLimit && !cache.containsKey(_identity)) {
      cache.remove(cache.keys.first);
    }
    cache[_identity] = summary;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final carPadModeEnabled =
        ref.watch(
          settingsProvider.select((settings) => settings.carPadModeEnabled),
        ) ||
        CarDisplayLayout.wideOf(context);
    final detail = ref.watch(onlinePlaylistDetailProvider(_key));
    final loaded = detail.asData?.value;
    final coverUrl = _artist && widget.fromPlayback
        ? _playbackArtistCover(loaded)
        : _summary?.coverUrl;
    if (loaded != null) {
      _lastPlaylist = _withDiscoveryArtwork(loaded, coverUrl);
      // Restore the same cached range before PageStorage restores its offset.
      ref.read(onlinePlaylistTrackLimitCacheProvider)[_identity] = _trackLimit;
    }
    final cached = _lastPlaylist;
    if (_artist) {
      // Song loading/failure must not remove the independently loaded catalog.
      final playlist = cached ?? PlaylistInfo(
        id: widget.playlistId, source: widget.source,
        name: _summary?.name ?? (widget.fromPlayback ? _playerArtist?.name : null) ?? '歌手详情',
        coverUrl: coverUrl, tracks: const [],
      );
      return _buildPlaylist(context, playlist,
        carPadModeEnabled: carPadModeEnabled,
        loadingMore: detail.isLoading,
        loadMoreError: detail.hasError ? _friendlyError(detail.error!) : null,
      );
    }
    if (cached != null && loaded == null) {
      final loadMoreError = detail.whenOrNull(
        error: (error, _) => _friendlyError(error),
      );
      return _buildPlaylist(
        context,
        cached,
        carPadModeEnabled: carPadModeEnabled,
        loadingMore: detail.isLoading,
        loadMoreError: loadMoreError,
      );
    }
    return detail.when(
      loading: () => _DetailLoading(
        summary: _summary,
        coverUrl: coverUrl,
        source: widget.source,
        playlistId: widget.playlistId,
        kind: widget.kind,
        carPadModeEnabled: carPadModeEnabled,
        onBack: widget.onBack,
      ),
      error: (error, _) => _DetailError(
        summary: _summary,
        coverUrl: coverUrl,
        source: widget.source,
        playlistId: widget.playlistId,
        kind: widget.kind,
        message: _friendlyError(error),
        onRetry: () => _invalidateDetail(retry: true),
        carPadModeEnabled: carPadModeEnabled,
        onBack: widget.onBack,
      ),
      data: (playlist) => _buildPlaylist(
        context,
        _withDiscoveryArtwork(playlist, coverUrl),
        carPadModeEnabled: carPadModeEnabled,
      ),
    );
  }

  PlaylistInfo _withDiscoveryArtwork(PlaylistInfo playlist, String? coverUrl) {
    final summary = _summary;
    final artwork = (_artist && widget.fromPlayback) || coverUrl?.trim().isNotEmpty == true
        ? coverUrl
        : playlist.coverUrl;
    final name = _artist ? summary?.name ?? playlist.name : playlist.name;
    if (artwork == playlist.coverUrl && name == playlist.name) return playlist;
    return PlaylistInfo(
      id: playlist.id,
      name: name,
      source: playlist.source,
      tracks: playlist.tracks,
      coverUrl: artwork,
      creator: playlist.creator,
      description: playlist.description,
      playCount: playlist.playCount,
      trackCount: playlist.trackCount,
      hasMoreTracks: playlist.hasMoreTracks,
    );
  }

  Widget _buildPlaylist(
    BuildContext context,
    PlaylistInfo playlist, {
    required bool carPadModeEnabled,
    bool loadingMore = false,
    String? loadMoreError,
  }) {
    final local = _artist || _album
        ? null
        : _findSavedPlaylist(ref.watch(localPlaylistsProvider), playlist);
    if (_album) ref.watch(albumTrackMatchesProvider);
    final queue = _queueFor(playlist);

    final artworkProvider = networkPlaylistArtworkProvider(
      playlist.coverUrl,
      size: _summary == null ? 1200 : discoveryPlaylistArtworkSize,
    );
    final wide = playlistDetailUsesWideLayout(
      context,
      carPadModeEnabled: carPadModeEnabled,
    );
    final albumSlivers = _artist && _artistAlbums ? _buildAlbumCatalog() : const <Widget>[];
    final metadata = [
      playlist.source.label,
      if (playlist.creator?.trim().isNotEmpty == true) playlist.creator!.trim(),
      '${playlist.totalTracks} 首',
      if (playlist.playCount != null)
        '${_compactCount(playlist.playCount!)} 次播放',
    ].join(' · ');
    return PlaylistArtworkTheme(
      artworkProvider: artworkProvider,
      cacheKey: _onlineArtworkCacheKey(
        widget.source,
        widget.playlistId,
        playlist.coverUrl,
        kind: widget.kind,
      ),
      immersiveStatusBar: !wide,
      child: Builder(
        builder: (context) {
          final scheme = Theme.of(context).colorScheme;
          Future<void> refresh() async {
            _invalidateDetail();
            if (_artist && _artistAlbums) {
              await Future.wait([for (final offset in _albumOffsets)
                ref.read(artistAlbumPageProvider((source: widget.source, id: widget.playlistId, offset: offset)).future)]);
            } else {
              await ref.read(onlinePlaylistDetailProvider(_key).future);
            }
          }

          Widget actionsWith(EdgeInsetsGeometry padding) {
            if (_artist && _artistAlbums) return const SizedBox.shrink();
            return PlaylistDetailActions(
              onPlay: queue.isEmpty || (_artist && _artistAlbums)
                  ? null
                  : () => _playQueue(playlist, queue.first),
              showFavorite: !_artist && !_album,
              onFavorite: _artist || _album || _saving
                  ? null
                  : () => _toggleFavorite(playlist, local),
              saving: _saving,
              removingFavorite: _removingFavorite,
              saved: local != null,
              favoriteLabel: widget.kind == OnlineCollectionKind.leaderboard
                  ? (local != null ? '已收藏' : '收藏榜单')
                  : null,
              padding: padding,
            );
          }

          final hasTrackFooter =
              loadingMore || (loadMoreError != null && playlist.hasMoreTracks);
          final trackSlivers = <Widget>[
            if (_artist) SliverToBoxAdapter(child: _artistSegments()),
            if (_artist && _artistAlbums) ...albumSlivers
            else ...[
            SliverToBoxAdapter(
              child: _PlaylistTracksHeading(
                popular: _artist,
                count: playlist.tracks.length,
                total: playlist.totalTracks,
                trailing: _album ? _albumSelectionControls(playlist) : null,
              ),
            ),
            if (_artist && playlist.tracks.isEmpty && loadingMore)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(12, 0, 12,
                  ShellBottomArea.contentPadding(context, 150)),
                sliver: SliverList.separated(
                  itemCount: wide ? 8 : 5,
                  separatorBuilder: (_, _) => _trackListDivider(context, scheme),
                  itemBuilder: (_, _) => const _DetailTrackSkeleton(),
                ),
              )
            else if (_artist && playlist.tracks.isEmpty && loadMoreError != null)
              SliverToBoxAdapter(child: _LoadMoreTracksError(message: loadMoreError,
                onRetry: () => _invalidateDetail(retry: true)))
            else if (playlist.tracks.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    _artist ? '这位歌手暂时没有可用歌曲' : '这个${widget.kind.label}暂时没有可用歌曲',
                  ),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  0,
                  12,
                  hasTrackFooter ? 0 : 156,
                ),
                sliver: SliverList.separated(
                  itemCount: playlist.tracks.length,
                  separatorBuilder: (_, _) =>
                      _trackListDivider(context, scheme),
                  itemBuilder: (context, index) {
                    if (!loadingMore && loadMoreError == null) {
                      _requestMoreTracksIfNeeded(playlist, index);
                    }
                    final music = playlist.tracks[index];
                    final entry = _album ? queue[index] : queue.where((item) {
                      final json = item.musicJson;
                      return json != null && json['id'] == music.id;
                    }).firstOrNull;
                    return Center(
                      child: ConstrainedBox(
                        constraints: CarDisplayLayout.contentConstraints(
                          context,
                          maxWidth: 900,
                        ),
                        child: _album ? _AlbumTrackTile(
                          key: ValueKey('album-track-${_trackKey(music)}'),
                          original: music, effective: _effectiveMusic(music), index: index,
                          batchMode: _batchMode, submitting: _batchSubmitting,
                          selected: _selectedTracks.contains(_trackKey(music)),
                          onToggleSelected: () => setState(() {
                            if (!_selectedTracks.add(_trackKey(music))) _selectedTracks.remove(_trackKey(music));
                          }),
                          onPlay: entry == null ? null : () => _playQueue(playlist, entry),
                          onAdd: () => _addAlbumTracks([music]),
                          onMatch: () => _matchAlbumTrack(music),
                        ) : _OnlinePlaylistTrackTile(
                          music: music,
                          onAddToPlaylist: _artist
                              ? () => addMusicToChosenPlaylist(
                                  context,
                                  ref,
                                  music,
                                )
                              : null,
                          onPlay: entry == null
                              ? null
                              : () => _playQueue(playlist, entry),
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (loadingMore)
              const SliverToBoxAdapter(child: _LoadMoreTracksIndicator())
            else if (loadMoreError != null && playlist.hasMoreTracks)
              SliverToBoxAdapter(
                child: _LoadMoreTracksError(
                  message: loadMoreError,
                  onRetry: () => _invalidateDetail(retry: true),
                ),
              ),
            ],
          ];

          return SlidableAutoCloseBehavior(child: Scaffold(
            backgroundColor: scheme.surface,
            bottomNavigationBar: _album && _batchMode ? _albumBatchBar(playlist) : null,
            body: wide
                ? PlaylistWideBody(
                    topBar: ImmersivePlaylistTopBar(
                      title: _detailLabel,
                      leading: _detailBackButton(widget.onBack, onImage: !wide),
                      onImage: false,
                    ),
                    infoPane: PlaylistWideInfoPane(
                      artworkProvider: artworkProvider,
                      artworkLoading: _artist && loadingMore && !_artistAlbums && artworkProvider == null,
                      artworkHeroTag: onlinePlaylistArtworkHeroTag(
                        playlist.source,
                        playlist.id,
                        kind: widget.kind,
                      ),
                      title: playlist.name,
                      metadata: metadata,
                      description: playlist.description,
                      actions: actionsWith(const EdgeInsets.only(top: 4)),
                    ),
                    right: AppScrollbar(
                      controller: _scrollController,
                      child: AppRefreshIndicator(
                        onRefresh: refresh,
                        child: CustomScrollView(
                          controller: _scrollController,
                          key: PageStorageKey(
                            'online-${widget.kind.name}-wide-${playlist.source.code}-${playlist.id}',
                          ),
                          physics: const AlwaysScrollableScrollPhysics(
                            parent: BouncingScrollPhysics(),
                          ),
                          slivers: trackSlivers,
                        ),
                      ),
                    ),
                  )
                : AppScrollbar(
                    controller: _scrollController,
                    child: AppRefreshIndicator(
                      onRefresh: refresh,
                      child: CustomScrollView(
                        controller: _scrollController,
                        key: PageStorageKey(
                          'online-${widget.kind.name}-${playlist.source.code}-${playlist.id}',
                        ),
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        slivers: [
                          SliverToBoxAdapter(
                            child: ImmersivePlaylistHeader(
                              artworkProvider: artworkProvider,
                              artworkLoading: _artist && loadingMore && !_artistAlbums && artworkProvider == null,
                              artworkHeroTag: onlinePlaylistArtworkHeroTag(
                                playlist.source,
                                playlist.id,
                                kind: widget.kind,
                              ),
                              topBar: ImmersivePlaylistTopBar(
                                title: _detailLabel,
                                leading: _detailBackButton(widget.onBack, onImage: true),
                              ),
                            ),
                          ),
                          SliverToBoxAdapter(
                            child: PlaylistDetailInfo(
                              title: playlist.name,
                              metadata: metadata,
                              description: playlist.description,
                            ),
                          ),
                          SliverToBoxAdapter(
                            child: actionsWith(
                              const EdgeInsets.fromLTRB(16, 4, 16, 8),
                            ),
                          ),
                          ...trackSlivers,
                        ],
                      ),
                    ),
                  ),
          ));
        },
      ),
    );
  }

  Future<void> _playQueue(
    PlaylistInfo playlist,
    DownloadHistoryEntry selectedEntry, {
    Iterable<MusicInfo>? tracks,
  }) async {
    final queue = _queueFor(playlist, tracks: tracks);
    final entry = _matchingQueueEntry(queue, selectedEntry);
    if (entry == null) return;
    final available = await ensureQueueEntryMusicSourceAvailable(context, entry);
    if (!available || !mounted) return;
    final player = ref.read(playerControllerProvider.notifier);
    final api = ref.read(musicApiProvider);

    openPlayer(context, returnLocation: _returnLocation);
    final playback = player.playFromPlaylistQueue(entry, queue);
    if (tracks == null && playlist.hasMoreTracks && !_album) {
      unawaited(
        _expandOnlinePlaylistQueue(
          api: api,
          player: player,
          playlist: playlist,
          kind: widget.kind,
          initialQueue: queue,
          artistLoadedLimit: _savedTrackLimit,
        ),
      );
    }
    await playback;
  }

  Future<void> _toggleFavorite(
    PlaylistInfo playlist,
    LocalPlaylist? savedPlaylist,
  ) async {
    if (_saving || _album || _artist) return;
    final removing = savedPlaylist != null;
    setState(() {
      _saving = true;
      _removingFavorite = removing;
    });
    try {
      final notifier = ref.read(localPlaylistsProvider.notifier);
      if (savedPlaylist == null) {
        final api = ref.read(musicApiProvider);
        final loaded = widget.kind == OnlineCollectionKind.leaderboard
            ? await api.getLeaderboard(
                source: playlist.source,
                boardId: playlist.id,
              )
            : await api.parsePlaylist(
                input: playlist.id,
                source: playlist.source,
              );
        final fullPlaylist = _withDiscoveryArtwork(loaded, _summary?.coverUrl);
        await notifier.importOnline(fullPlaylist);
      } else {
        await notifier.delete(savedPlaylist.id);
      }
      if (!mounted) return;
      showAppToast(
        context,
        removing ? '已取消收藏' : '已完整收藏到我的歌单',
        type: AppToastType.success,
      );
    } catch (error) {
      if (!mounted) return;
      showAppToast(
        context,
        '${removing ? '取消收藏' : '收藏'}失败：$error',
        type: AppToastType.error,
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _removingFavorite = false;
        });
      }
    }
  }

  Widget _artistSegments() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Center(child: ConstrainedBox(
      constraints: CarDisplayLayout.contentConstraints(context, maxWidth: 900),
      child: SearchSegments(
        prefix: 'artist-content',
        options: const [(id: 'songs', label: '歌曲'), (id: 'albums', label: '专辑')],
        selected: _artistAlbums ? 1 : 0,
        semanticsSuffix: '',
        onSelect: (index) => setState(() => _artistAlbums = index == 1),
      ),
    )),
  );

  List<Widget> _buildAlbumCatalog() {
    final albums = <AlbumInfo>[];
    AlbumPage? last;
    AsyncValue<AlbumPage>? pending;
    for (final offset in _albumOffsets) {
      final page = ref.watch(artistAlbumPageProvider((
        source: widget.source, id: widget.playlistId, offset: offset,
      )));
      final data = page.asData?.value;
      if (data == null) {pending = page; break;}
      last = data;
      albums.addAll(data.albums);
    }
    final loadedPage = last;
    final loadState = pending;
    final groups = groupArtistAlbums(albums);
    return [
      if (albums.isNotEmpty) SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList.separated(
          itemCount: groups.length,
          separatorBuilder: (_, _) => _trackListDivider(context, Theme.of(context).colorScheme),
          itemBuilder: (context, index) => Center(child: ConstrainedBox(
            constraints: CarDisplayLayout.contentConstraints(context, maxWidth: 900),
            child: AlbumResultTile(album: groups[index].representative,
              variants: groups[index].variants, fromPlayback: widget.fromPlayback),
          )),
        ),
      ),
      if (loadState?.isLoading == true)
        const SliverToBoxAdapter(child: _LoadMoreTracksIndicator())
      else if (loadState?.hasError == true)
        SliverToBoxAdapter(child: _LoadMoreTracksError(
          message: _friendlyError(loadState!.error!),
          onRetry: () => _invalidateDetail(retry: true),
        ))
      else if (albums.isEmpty)
        const SliverFillRemaining(hasScrollBody: false,
          child: Center(child: Text('暂无可用专辑')))
      else if (loadedPage?.hasMore == true)
        SliverToBoxAdapter(child: Center(child: TextButton(
          onPressed: () => setState(() {
            final next = loadedPage!.offset + loadedPage.limit;
            if (!_albumOffsets.contains(next)) _albumOffsets.add(next);
          }),
          child: const Text('加载更多专辑'),
        ))),
      const SliverToBoxAdapter(child: SizedBox(height: 156)),
    ];
  }

  Widget _albumSelectionControls(PlaylistInfo playlist) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (_batchMode) IconButton(
        tooltip: _selectedTracks.containsAll(playlist.tracks.map(_trackKey)) ? '取消全选' : '全选',
        onPressed: _batchSubmitting ? null : () => setState(() {
          if (_selectedTracks.containsAll(playlist.tracks.map(_trackKey))) {
            _selectedTracks.clear();
          } else {
            _selectedTracks..clear()..addAll(playlist.tracks.map(_trackKey));
          }
        }),
        icon: const Icon(Icons.select_all_rounded),
      ),
      IconButton(
        tooltip: _batchMode ? '退出批量操作' : '批量操作',
        onPressed: _batchSubmitting || playlist.tracks.isEmpty ? null : () => setState(() {
          _batchMode = !_batchMode;
          if (!_batchMode) _selectedTracks.clear();
        }),
        icon: Icon(_batchMode ? Icons.close_rounded : Icons.checklist_rounded),
      ),
    ],
  );

  List<MusicInfo> _selectedAlbumTracks(PlaylistInfo playlist) => [
    for (final music in playlist.tracks)
      if (_selectedTracks.contains(_trackKey(music))) music,
  ];

  Widget _albumBatchBar(PlaylistInfo playlist) {
    final tracks = _selectedAlbumTracks(playlist);
    final area = ShellBottomArea.maybeOf(context);
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final reserve = area?.navigationMode == AppNavigationMode.singleCapsule
        ? toolbarHeightFor(context) + (safeBottom > toolbarMinimumBottomInset
            ? safeBottom : toolbarMinimumBottomInset)
        : area?.floatingExtent ?? 0.0;
    return Padding(
      padding: EdgeInsets.only(bottom: reserve),
      child: _AlbumBatchBar(
      selectedCount: tracks.length, submitting: _batchSubmitting,
      onAdd: tracks.isEmpty ? null : () => _addAlbumTracks(tracks),
      onDownload: tracks.isEmpty ? null : () => _downloadAlbumTracks(tracks),
      onPlay: tracks.isEmpty ? null : () => _playSelectedAlbum(playlist, tracks),
    ));
  }

  Future<void> _addAlbumTracks(List<MusicInfo> originals) async {
    if (_batchSubmitting || originals.isEmpty) return;
    // Capture the chosen versions once; the target sheet must not rematch them.
    final musics = originals.map(_effectiveMusic).toList(growable: false);
    setState(() => _batchSubmitting = true);
    try {
      final destination = await showPlaylistBrowserSheet(context, mode: PlaylistBrowserMode.addSongs);
      if (!mounted || destination == null || !destination.startsWith('/playlists/')) return;
      final store = ref.read(localPlaylistsProvider.notifier);
      final id = destination.substring('/playlists/'.length);
      final target = store.byId(id);
      if (target == null) {
        showAppToast(context, '歌单不存在或已被删除', type: AppToastType.warning);
        return;
      }
      final count = await store.addMusics(id, musics);
      if (!mounted) return;
      showAppToast(context, count == 0 ? '所选歌曲已在「${target.name}」中' : '已添加 $count 首歌曲到「${target.name}」',
        type: count == 0 ? AppToastType.info : AppToastType.success);
      setState(() {_batchMode = false; _selectedTracks.clear();});
    } catch (error) {
      if (mounted) showAppToast(context, '添加到歌单失败：$error', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => _batchSubmitting = false);
    }
  }

  Future<void> _matchAlbumTrack(MusicInfo original) async {
    final source = widget.source;
    final albumId = widget.playlistId;
    final key = albumTrackMatchKey(source: source, albumId: albumId, original: original);
    final expected = ref.read(albumTrackMatchesProvider)[key];
    final replacement = await showTrackMatchPicker(context,
      title: original.name, artist: original.singer,
      initialSource: expected?.source ?? original.source,
    );
    if (!mounted || replacement == null) return;
    try {
      final saved = await ref.read(albumTrackMatchesProvider.notifier).setMatch(
        source: source, albumId: albumId, original: original,
        replacement: replacement, expected: expected,
      );
      if (mounted) showAppToast(context, saved ? '已保存手选匹配' : '匹配已更新，保留较新的选择',
        type: saved ? AppToastType.success : AppToastType.info);
    } catch (error) {
      if (mounted) showAppToast(context, '保存匹配失败：$error', type: AppToastType.error);
    }
  }

  Future<void> _playSelectedAlbum(PlaylistInfo playlist, List<MusicInfo> tracks) async {
    final queue = _queueFor(playlist, tracks: tracks);
    if (queue.isEmpty) return;
    await _playQueue(playlist, queue.first, tracks: tracks);
  }

  Future<void> _downloadAlbumTracks(List<MusicInfo> originals) async {
    if (_batchSubmitting) return;
    final progress = ref.read(downloadProgressProvider);
    final musics = originals.map(_effectiveMusic)
        .where((music) => !progress.isMusicBusy(music)).toList(growable: false);
    if (musics.isEmpty) return;
    setState(() => _batchSubmitting = true);
    try {
      final available = await ensureOnlineMusicSourcesAvailable(context, musics.map((music) => music.source));
      if (!mounted || !available) return;
      final preference = ref.read(settingsProvider).batchDownloadQuality;
      final results = await ref.read(downloadServiceProvider).downloadMany(
        musics: musics, embed: const EmbedRequest.richest(), qualityPreference: preference,
      );
      if (!mounted) return;
      final failed = results.where((result) => !result.success).length;
      showAppToast(context, failed == 0 ? '批量下载完成' : '$failed 首下载失败',
        type: failed == 0 ? AppToastType.success : AppToastType.warning);
      setState(() {_batchMode = false; _selectedTracks.clear();});
    } catch (error) {
      if (mounted) showAppToast(context, '批量下载失败：$error', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => _batchSubmitting = false);
    }
  }

  void _requestMoreTracksIfNeeded(PlaylistInfo playlist, int index) {
    if (index < playlist.tracks.length - 6) return;
    _loadMoreTracks(playlist);
  }

  void _loadMoreTracks(PlaylistInfo playlist) {
    if (!TickerMode.valuesOf(context).enabled) return;
    if (!playlist.hasMoreTracks) return;
    if (_trackLimit >= playlist.totalTracks) return;
    final next = _trackLimit + onlinePlaylistDetailTrackPageSize;
    final target = next > playlist.totalTracks ? playlist.totalTracks : next;
    if (target <= _trackLimit) return;
    final identity = _identity;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _identity != identity ||
          !TickerMode.valuesOf(context).enabled ||
          _trackLimit >= target) {
        return;
      }
      setState(() => _trackLimit = target);
    });
  }
}

class _AlbumTrackTile extends ConsumerWidget {
  const _AlbumTrackTile({super.key, required this.original, required this.effective,
    required this.index, required this.batchMode, required this.submitting,
    required this.selected, required this.onToggleSelected, required this.onPlay,
    required this.onAdd, required this.onMatch});

  final MusicInfo original;
  final MusicInfo effective;
  final int index;
  final bool batchMode;
  final bool submitting;
  final bool selected;
  final VoidCallback onToggleSelected;
  final VoidCallback? onPlay;
  final VoidCallback onAdd;
  final VoidCallback onMatch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final task = ref.watch(downloadProgressProvider.select(
      (state) => state.latestTaskForMusic(effective),
    ));
    final selectionEnabled = !submitting && task?.isBusy != true;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final row = Semantics(
      selected: batchMode && selected,
      label: '第 ${index + 1} 首',
      child: TrackResultRow(
        name: original.name, singer: original.singer,
        album: original.albumName, sourceLabel: original.source.label,
        interval: original.interval,
        backgroundColor: batchMode && selected
            ? scheme.primaryContainer.withValues(alpha: 0.56) : Colors.transparent,
        cover: SizedBox.square(dimension: 44, child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: original.meta.picUrl?.trim().isNotEmpty == true
              ? DiscoveryPlaylistCover(url: original.meta.picUrl, size: 44)
              : ColoredBox(color: scheme.secondaryContainer,
                  child: Center(child: Text('${index + 1}',
                    style: TextStyle(color: scheme.onSecondaryContainer)))),
        )),
        onPlay: batchMode ? (selectionEnabled ? onToggleSelected : null) : onPlay,
        actions: [
          AnimatedSize(
            duration: reduceMotion ? Duration.zero : AppMotion.medium,
            curve: AppMotion.emphasized,
            alignment: Alignment.centerRight,
            child: AnimatedSwitcher(
              duration: reduceMotion ? Duration.zero : AppMotion.medium,
              switchInCurve: AppMotion.emphasizedDecelerate,
              switchOutCurve: AppMotion.emphasizedAccelerate,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(begin: const Offset(0.18, 0), end: Offset.zero).animate(animation),
                  child: child,
                ),
              ),
              child: batchMode ? SizedBox.square(
                key: const ValueKey('playlist-select-action'), dimension: 44,
                child: Center(child: Checkbox(
                  value: selected, visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: selectionEnabled ? (_) => onToggleSelected() : null,
                )),
              ) : ExpressiveDownloadButton(
                key: ValueKey('search-result-download-${original.id}'),
                isLoading: task?.isBusy ?? false,
                isDone: task?.stage == DownloadStage.done,
                progress: task?.fraction,
                onPressed: task?.isBusy == true || task?.stage == DownloadStage.done
                    ? null : () => showQualityPickerSheet(context, effective),
                tooltip: task?.stage == DownloadStage.done ? '已下载完成'
                    : task?.stage == DownloadStage.failed ? '重新选择音质下载' : '选择音质下载',
                size: 36, tapTargetSize: 40, tonal: true,
              ),
            ),
          ),
        ],
      ),
    );
    if (batchMode) return Theme(
      data: Theme.of(context).copyWith(colorScheme: selected ? scheme.copyWith(
        onSurface: scheme.onPrimaryContainer,
        onSurfaceVariant: scheme.onPrimaryContainer.withValues(alpha: 0.8),
      ) : scheme),
      child: row,
    );
    return LayoutBuilder(builder: (context, constraints) => Slidable(
      key: ValueKey('album-slide-${original.source.code}-${original.id}'),
      endActionPane: ActionPane(
        motion: const BehindMotion(),
        extentRatio: tightTrackActionExtent(2, constraints.maxWidth,
          textScale: MediaQuery.textScalerOf(context).scale(12) / 12),
        children: [
          SlidableAction(
            autoClose: false,
            onPressed: (actionContext) async {
              await Slidable.of(actionContext)?.close();
              onAdd();
            },
            padding: tightTrackActionPadding,
            flex: tightTrackActionFlex('添加到歌单'),
            backgroundColor: scheme.secondaryContainer,
            foregroundColor: scheme.onSecondaryContainer,
            icon: Icons.playlist_add_rounded, label: '添加到歌单',
          ),
          SlidableAction(
            onPressed: (_) => onMatch(), padding: tightTrackActionPadding,
            flex: tightTrackActionFlex('更换匹配'),
            backgroundColor: scheme.secondaryContainer,
            foregroundColor: scheme.onSecondaryContainer,
            icon: Icons.search_rounded, label: '更换匹配',
          ),
        ],
      ),
      child: row,
    ));
  }
}

/// The saved-playlist batch bar's layout and actions, without album-inapplicable
/// remove/move operations. The normal shell navigation remains untouched.
class _AlbumBatchBar extends StatelessWidget {
  const _AlbumBatchBar({required this.selectedCount, required this.submitting,
    required this.onAdd, required this.onDownload, required this.onPlay});
  final int selectedCount;
  final bool submitting;
  final VoidCallback? onAdd;
  final VoidCallback? onDownload;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget action(IconData icon, String label, VoidCallback? onPressed) {
      final enabled = !submitting && onPressed != null;
      final color = enabled ? scheme.onSurfaceVariant : scheme.onSurface.withValues(alpha: 0.34);
      return Expanded(child: Semantics(button: true, enabled: enabled, label: label,
        child: Material(color: Colors.transparent, child: InkWell(
          onTap: enabled ? onPressed : null,
          child: AnimatedOpacity(duration: AppMotion.short, opacity: enabled ? 1 : 0.72,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 21, color: color), const SizedBox(height: 3),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w500)),
            ])),
        )),
      ));
    }
    return Material(
      key: const ValueKey('playlist-batch-bottom-bar'),
      color: scheme.surfaceContainer, elevation: 5,
      shadowColor: scheme.shadow.withValues(alpha: 0.18),
      child: SafeArea(top: false, bottom: ShellBottomArea.maybeOf(context) == null, child: Container(
        height: 64,
        decoration: BoxDecoration(border: Border(top: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.42)))),
        child: Row(children: [
          action(Icons.playlist_add_rounded, '添加到歌单', onAdd),
          action(submitting ? Icons.downloading_rounded : Icons.download_rounded,
            selectedCount == 0 ? '下载选中' : '下载 $selectedCount 首', onDownload),
          action(Icons.playlist_play_rounded,
            selectedCount == 0 ? '播放选中' : '播放 $selectedCount 首', onPlay),
        ]),
      )),
    );
  }
}

class _OnlinePlaylistTrackTile extends ConsumerStatefulWidget {
  const _OnlinePlaylistTrackTile({
    required this.music,
    required this.onPlay,
    this.onAddToPlaylist,
  });

  final MusicInfo music;
  final VoidCallback? onPlay;
  final VoidCallback? onAddToPlaylist;

  @override
  ConsumerState<_OnlinePlaylistTrackTile> createState() =>
      _OnlinePlaylistTrackTileState();
}

class _OnlinePlaylistTrackTileState
    extends ConsumerState<_OnlinePlaylistTrackTile> {
  late bool _fallbackRequested = _embeddedCover.isEmpty;

  String get _embeddedCover => widget.music.meta.picUrl?.trim() ?? '';

  @override
  void didUpdateWidget(covariant _OnlinePlaylistTrackTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.music.id != widget.music.id) {
      _fallbackRequested = _embeddedCover.isEmpty;
    }
  }

  void _requestFallbackCover() {
    if (_fallbackRequested || !mounted) return;
    setState(() => _fallbackRequested = true);
  }

  @override
  Widget build(BuildContext context) {
    final task = ref.watch(
      downloadProgressProvider.select(
        (value) => value.latestTaskForMusic(widget.music),
      ),
    );
    final fallback = _fallbackRequested
        ? ref.watch(onlineTrackCoverProvider(OnlineTrackCoverKey(widget.music)))
        : null;
    final resolved = fallback?.asData?.value?.trim() ?? '';
    final coverUrl = resolved.isNotEmpty ? resolved : _embeddedCover;
    return SearchResultTile(
      music: widget.music,
      coverUrl: coverUrl,
      coverLoading: fallback?.isLoading ?? false,
      onCoverError: _requestFallbackCover,
      downloadTask: task,
      onDownload: () => showQualityPickerSheet(context, widget.music),
      onPlay: widget.onPlay ?? () {},
      onAddToPlaylist: widget.onAddToPlaylist,
    );
  }
}

class _DetailLoading extends StatelessWidget {
  const _DetailLoading({
    required this.summary,
    required this.coverUrl,
    required this.source,
    required this.playlistId,
    required this.kind,
    required this.carPadModeEnabled,
    this.onBack,
  });

  final PlaylistSummary? summary;
  final String? coverUrl;
  final MusicSource source;
  final String playlistId;
  final OnlineCollectionKind kind;
  final bool carPadModeEnabled;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final item = summary;
    final artworkProvider = networkPlaylistArtworkProvider(
      coverUrl,
      size: discoveryPlaylistArtworkSize,
    );
    final wide = playlistDetailUsesWideLayout(
      context,
      carPadModeEnabled: carPadModeEnabled,
    );
    final detailLabel = '${kind.label}详情';
    final title = item?.name ?? detailLabel;
    final metadata = item == null
        ? '正在读取${kind.label}信息'
        : _summaryMetadata(item);
    final descriptionLoading = item?.description?.trim().isEmpty ?? true;
    return PlaylistArtworkTheme(
      artworkProvider: artworkProvider,
      cacheKey: _onlineArtworkCacheKey(
        source,
        playlistId,
        coverUrl,
        kind: kind,
      ),
      immersiveStatusBar: !wide,
      child: Builder(
        builder: (context) {
          final scheme = Theme.of(context).colorScheme;
          final skeletonSliver = SliverPadding(
            padding: EdgeInsets.fromLTRB(
              12,
              0,
              12,
              ShellBottomArea.contentPadding(context, 150),
            ),
            sliver: SliverList.separated(
              itemCount: wide ? 8 : 5,
              separatorBuilder: (_, _) => _trackListDivider(context, scheme),
              itemBuilder: (_, _) => const _DetailTrackSkeleton(),
            ),
          );
          return Scaffold(
            backgroundColor: scheme.surface,
            body: wide
                ? PlaylistWideBody(
                    topBar: ImmersivePlaylistTopBar(
                      title: detailLabel,
                      leading: _detailBackButton(onBack, onImage: !wide),
                      onImage: false,
                    ),
                    infoPane: PlaylistWideInfoPane(
                      artworkProvider: artworkProvider,
                      artworkLoading: artworkProvider == null,
                      artworkHeroTag: onlinePlaylistArtworkHeroTag(
                        source,
                        playlistId,
                        kind: kind,
                      ),
                      title: title,
                      metadata: metadata,
                      description: item?.description,
                      descriptionLoading: descriptionLoading,
                      actions: PlaylistDetailActions(
                        showFavorite: kind != OnlineCollectionKind.artist && kind != OnlineCollectionKind.album,
                        loading: true,
                        padding: const EdgeInsets.only(top: 4),
                      ),
                    ),
                    right: CustomScrollView(
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      slivers: [
                        SliverToBoxAdapter(
                          child: _PlaylistTracksHeading(
                            popular: kind == OnlineCollectionKind.artist,
                            count: item?.trackCount,
                          ),
                        ),
                        skeletonSliver,
                      ],
                    ),
                  )
                : CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    slivers: [
                      SliverToBoxAdapter(
                        child: ImmersivePlaylistHeader(
                          artworkProvider: artworkProvider,
                          artworkLoading: artworkProvider == null,
                          artworkHeroTag: onlinePlaylistArtworkHeroTag(
                            source,
                            playlistId,
                            kind: kind,
                          ),
                          topBar: ImmersivePlaylistTopBar(
                            title: detailLabel,
                            leading: _detailBackButton(onBack, onImage: true),
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: PlaylistDetailInfo(
                          title: title,
                          metadata: metadata,
                          description: item?.description,
                          descriptionLoading: descriptionLoading,
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: PlaylistDetailActions(
                          loading: true,
                          showFavorite: kind != OnlineCollectionKind.artist && kind != OnlineCollectionKind.album,
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: _PlaylistTracksHeading(
                          popular: kind == OnlineCollectionKind.artist,
                          count: item?.trackCount,
                        ),
                      ),
                      skeletonSliver,
                    ],
                  ),
          );
        },
      ),
    );
  }
}

class _DetailError extends StatelessWidget {
  const _DetailError({
    required this.summary,
    required this.coverUrl,
    required this.source,
    required this.playlistId,
    required this.kind,
    required this.message,
    required this.onRetry,
    required this.carPadModeEnabled,
    this.onBack,
  });

  final PlaylistSummary? summary;
  final String? coverUrl;
  final MusicSource source;
  final String playlistId;
  final OnlineCollectionKind kind;
  final String message;
  final VoidCallback onRetry;
  final bool carPadModeEnabled;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final item = summary;
    final artworkProvider = networkPlaylistArtworkProvider(
      coverUrl,
      size: discoveryPlaylistArtworkSize,
    );
    final wide = playlistDetailUsesWideLayout(
      context,
      carPadModeEnabled: carPadModeEnabled,
    );
    final detailLabel = '${kind.label}详情';
    final title = item?.name ?? detailLabel;
    final metadata = item == null ? source.label : _summaryMetadata(item);
    final errorContent = Center(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          28,
          24,
          28,
          ShellBottomArea.contentPadding(context, 140),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 44),
            const SizedBox(height: 14),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            IconButton.filledTonal(
              tooltip: '重试',
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      ),
    );
    return PlaylistArtworkTheme(
      artworkProvider: artworkProvider,
      cacheKey: _onlineArtworkCacheKey(
        source,
        playlistId,
        coverUrl,
        kind: kind,
      ),
      immersiveStatusBar: !wide,
      child: Builder(
        builder: (context) {
          final scheme = Theme.of(context).colorScheme;
          return Scaffold(
            backgroundColor: scheme.surface,
            body: wide
                ? PlaylistWideBody(
                    topBar: ImmersivePlaylistTopBar(
                      title: detailLabel,
                      leading: _detailBackButton(onBack, onImage: !wide),
                      onImage: false,
                    ),
                    infoPane: PlaylistWideInfoPane(
                      artworkProvider: artworkProvider,
                      artworkHeroTag: onlinePlaylistArtworkHeroTag(
                        source,
                        playlistId,
                        kind: kind,
                      ),
                      title: title,
                      metadata: metadata,
                      description: item?.description,
                    ),
                    right: errorContent,
                  )
                : CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    slivers: [
                      SliverToBoxAdapter(
                        child: ImmersivePlaylistHeader(
                          artworkProvider: artworkProvider,
                          artworkHeroTag: onlinePlaylistArtworkHeroTag(
                            source,
                            playlistId,
                            kind: kind,
                          ),
                          topBar: ImmersivePlaylistTopBar(
                            title: detailLabel,
                            leading: _detailBackButton(onBack, onImage: true),
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: PlaylistDetailInfo(
                          title: title,
                          metadata: metadata,
                          description: item?.description,
                        ),
                      ),
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: errorContent,
                      ),
                    ],
                  ),
          );
        },
      ),
    );
  }
}

class _PlaylistTracksHeading extends StatelessWidget {
  const _PlaylistTracksHeading({this.count, this.total, this.popular = false, this.trailing});

  final Widget? trailing;

  final bool popular;

  final int? count;
  final int? total;

  String get _label {
    final loaded = count;
    final all = total;
    final title = popular ? '热门歌曲' : '歌曲';
    if (loaded == null) return title;
    if (all != null && all > loaded) return '$title  $loaded/$all';
    return '$title  $loaded';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Center(
        child: ConstrainedBox(
          constraints: CarDisplayLayout.contentConstraints(
            context,
            maxWidth: 900,
          ),
          child: SizedBox(
            height: trailing == null ? 24 : 48,
            child: Row(children: [
              Expanded(child: Text(_label,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700, letterSpacing: 0))),
              if (trailing != null) trailing!,
            ]),
          ),
        ),
      ),
    );
  }
}

class _LoadMoreTracksIndicator extends StatelessWidget {
  const _LoadMoreTracksIndicator();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        ShellBottomArea.contentPadding(context, 156),
      ),
      child: const Center(
        child: SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      ),
    );
  }
}

class _LoadMoreTracksError extends StatelessWidget {
  const _LoadMoreTracksError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        ShellBottomArea.contentPadding(context, 156),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: CarDisplayLayout.contentConstraints(
            context,
            maxWidth: 900,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: '重试',
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailTrackSkeleton extends StatelessWidget {
  const _DetailTrackSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 与数据态的 SearchResultTile 行保持同宽同高（900 限宽居中、行高 62、
    // 封面 44），loading → data 切换不跳动。
    return Center(
      child: ConstrainedBox(
        constraints: CarDisplayLayout.contentConstraints(
          context,
          maxWidth: 900,
        ),
        child: SizedBox(
          key: const ValueKey('detail-track-skeleton'),
          height: 62,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 2, 2),
            child: Row(
              children: [
                const ClipRRect(
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                  child: SizedBox.square(
                    dimension: 44,
                    child: CoverLoadingSkeleton(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FractionallySizedBox(
                        widthFactor: 0.58,
                        child: Container(
                          height: 12,
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ),
                      const SizedBox(height: 9),
                      FractionallySizedBox(
                        widthFactor: 0.36,
                        child: Container(
                          height: 9,
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 44),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _trackListDivider(BuildContext context, ColorScheme scheme) {
  return Center(
    child: ConstrainedBox(
      constraints: CarDisplayLayout.contentConstraints(context, maxWidth: 900),
      child: Divider(
        height: 1,
        indent: 56,
        color: scheme.outlineVariant.withValues(alpha: 0.35),
      ),
    ),
  );
}

String _summaryMetadata(PlaylistSummary summary) {
  return [
    summary.source.label,
    if (summary.creator?.trim().isNotEmpty == true) summary.creator!.trim(),
    if (summary.trackCount != null) '${summary.trackCount} 首',
    if (summary.playCount != null) '${_compactCount(summary.playCount!)} 次播放',
  ].join(' · ');
}

String _onlineArtworkCacheKey(
  MusicSource source,
  String playlistId,
  String? coverUrl, {
  OnlineCollectionKind kind = OnlineCollectionKind.playlist,
}) {
  return 'online:${kind.name}:${source.code}:$playlistId:'
      '${coverUrl?.trim() ?? ''}';
}

List<DownloadHistoryEntry> _onlinePlaylistQueue(
  PlaylistInfo playlist,
  OnlineCollectionKind kind, {
  Iterable<MusicInfo>? tracks,
  MusicInfo Function(MusicInfo)? resolve,
}) {
  final prefix = switch (kind) {
    OnlineCollectionKind.album => 'album',
    OnlineCollectionKind.artist => 'artist',
    _ => 'online',
  };
  final queueId = '$prefix:${playlist.source.code}:${playlist.id}';
  final queue = <DownloadHistoryEntry>[];
  for (final music in tracks ?? playlist.tracks) {
    final entry = PlaylistTrack.fromMusicInfo(
      resolve?.call(music) ?? music,
    ).toQueueEntry(playlistId: kind == OnlineCollectionKind.album
        ? '$queueId:${music.source.code}:${music.id}' : queueId);
    if (entry != null) {
      queue.add(kind == OnlineCollectionKind.album ? DownloadHistoryEntry.fromJson({
        ...entry.toJson(),
        'id': 'playlist:$queueId:${queue.length}:${music.source.code}:${music.id}',
        'preservePlaylistPosition': true,
      }) : entry);
    }
  }
  return queue;
}

DownloadHistoryEntry? _matchingQueueEntry(
  Iterable<DownloadHistoryEntry> queue,
  DownloadHistoryEntry selected,
) {
  for (final entry in queue) {
    if (entry.id == selected.id) return entry;
  }
  if (selected.preservePlaylistPosition) return null;
  for (final entry in queue) {
    if (entry.sourceCode == selected.sourceCode && entry.musicId == selected.musicId) {
      return entry;
    }
  }
  return null;
}

Future<void> _expandOnlinePlaylistQueue({
  required MusicApi api,
  required PlayerController player,
  required PlaylistInfo playlist,
  required OnlineCollectionKind kind,
  required List<DownloadHistoryEntry> initialQueue,
  required int artistLoadedLimit,
}) async {
  try {
    if (kind == OnlineCollectionKind.artist) {
      var expected = initialQueue;
      final seen = playlist.tracks.map((track) => track.id).toSet();
      var total = playlist.totalTracks;
      for (
        var offset = artistLoadedLimit;
        offset < total;
        offset += onlinePlaylistDetailTrackPageSize
      ) {
        final page = await api.artistSongs(
          source: playlist.source,
          artistId: playlist.id,
          offset: offset,
          limit: onlinePlaylistDetailTrackPageSize,
        );
        if (page.tracks.isEmpty) break;
        total = page.total;
        final next = [
          ...expected,
          ..._onlinePlaylistQueue(
            playlist,
            kind,
            tracks: page.tracks.where((track) => seen.add(track.id)),
          ),
        ];
        if (!player.expandPlaylistQueue(
          expectedQueue: expected,
          expandedQueue: next,
        )) {
          break;
        }
        expected = next;
      }
      return;
    }
    if (kind == OnlineCollectionKind.album) return;
    final fullPlaylist = kind == OnlineCollectionKind.leaderboard
        ? await api.getLeaderboard(
            source: playlist.source,
            boardId: playlist.id,
          )
        : await api.parsePlaylist(input: playlist.id, source: playlist.source);
    final fullQueue = _onlinePlaylistQueue(fullPlaylist, kind);
    player.expandPlaylistQueue(
      expectedQueue: initialQueue,
      expandedQueue: fullQueue,
    );
  } catch (error) {
    await AppLogger.write(
      'player',
      'expand online playlist queue failed: $error',
    );
  }
}

LocalPlaylist? _findSavedPlaylist(
  List<LocalPlaylist> playlists,
  PlaylistInfo online,
) {
  for (final playlist in playlists) {
    if (playlist.originSourceCode == online.source.code &&
        playlist.originPlaylistId == online.id) {
      return playlist;
    }
  }
  return null;
}

String _compactCount(int count) {
  if (count >= 100000000) {
    return '${(count / 100000000).toStringAsFixed(count >= 1000000000 ? 0 : 1)}亿';
  }
  if (count >= 10000) {
    return '${(count / 10000).toStringAsFixed(count >= 100000 ? 0 : 1)}万';
  }
  return '$count';
}

String _friendlyError(Object error) {
  final value = error.toString().replaceFirst('Exception: ', '').trim();
  return value.isEmpty ? '歌单加载失败，请稍后重试' : value;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

Widget? _detailBackButton(VoidCallback? onBack, {required bool onImage}) =>
    onBack == null ? null : ImmersiveTopIconButton(
      tooltip: '返回', icon: Icons.arrow_back_rounded,
      onImage: onImage, onPressed: onBack,
    );
