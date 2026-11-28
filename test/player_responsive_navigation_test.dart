import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/lyric_info.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/core/ui/app_toast.dart';
import 'package:cy_shine_music/features/player/player_audio_handler.dart';
import 'package:cy_shine_music/features/player/player_controller.dart';
import 'package:cy_shine_music/features/player/lyric_parser.dart';
import 'package:cy_shine_music/features/player/player_page.dart';
import 'package:cy_shine_music/features/player/widgets/album_cluster.dart';
import 'package:cy_shine_music/features/player/widgets/karaoke_line_text.dart';
import 'package:cy_shine_music/features/player/widgets/karaoke_lyrics_view.dart';
import 'package:cy_shine_music/features/player/widgets/lyrics_panel.dart';
import 'package:cy_shine_music/features/player/widgets/spinning_cover_art.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:cy_shine_music/features/settings/widgets/settings_number_control.dart';
import 'package:cy_shine_music/features/shell/shell_route_utils.dart';
import 'package:cy_shine_music/router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('system back from debug returns to settings', (tester) async {
    final harness = await _pumpRoutedApp(tester, initialLocation: '/debug');

    expect(harness.router.routeInformationProvider.value.uri.path, '/debug');
    expect(await tester.binding.handlePopRoute(), isTrue);
    await _pumpUi(tester);

    expect(harness.router.routeInformationProvider.value.uri.path, '/settings');
    expect(tester.takeException(), isNull);
  });

  testWidgets('music sources remains a valid player return location', (
    tester,
  ) async {
    expect(
      normalizedPlayerReturnLocation('/settings/sources', '/songs'),
      '/settings/sources',
    );

    final harness = await _pumpRoutedApp(tester, initialLocation: '/songs');
    harness.router.go('/player', extra: '/settings/sources');
    await _pumpUi(tester);

    final player = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect(player.active, isTrue);
    expect(player.returnLocation, '/settings/sources');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compact remote player moves quality and source into the cover menu',
    (tester) async {
      final controller = await _pumpPlayer(
        tester,
        size: const Size(390, 844),
        currentMusic: _remoteMusic(),
        track: const PlayerTrack(
          id: 'tx:remote-song',
          kind: PlayerTrackKind.remote,
          title: '窄屏在线歌曲',
          artist: '不应在封面下重复的歌手',
          album: '测试专辑',
          sourceLabel: 'QQ',
          qualityLabel: '320k',
          availableQualityOptions: [
            QualityOption(type: Quality.k320, size: '9.48 MB'),
            QualityOption(type: Quality.k192),
            QualityOption(type: Quality.k128, size: '3.82 MB'),
          ],
          remoteUrl: 'https://audio.example/remote-song.mp3',
        ),
      );
      expect(
        tester
            .widget<SpinningCoverArt>(find.byType(SpinningCoverArt))
            .boxShadow,
        isNotEmpty,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayerPage)),
      );
      final playlist = await container
          .read(localPlaylistsProvider.notifier)
          .create('在线收藏');
      final music = _remoteMusic();

      expect(
        find.byKey(const ValueKey('player-compact-pager')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('player-wide-layout')), findsNothing);
      expect(find.byType(PageView), findsOneWidget);
      final pager = find.byKey(const ValueKey('player-compact-pager'));
      expect(
        find.byKey(const ValueKey('player-compact-pager-edge-guard')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('player-compact-album-clip')),
        findsOneWidget,
      );
      expect(tester.widget<PageView>(pager).clipBehavior, Clip.hardEdge);
      final edgeNotification = OverscrollIndicatorNotification(leading: false);
      edgeNotification.dispatch(tester.element(pager));
      expect(edgeNotification.accepted, isFalse);

      // Track metadata belongs to the header on every compact page and must
      // not be repeated below the cover.
      expect(find.text('窄屏在线歌曲'), findsOneWidget);
      expect(find.text('不应在封面下重复的歌手'), findsOneWidget);
      final title = tester.widget<Text>(
        find.byKey(const ValueKey('player-header-title')),
      );
      final artist = tester.widget<Text>(
        find.byKey(const ValueKey('player-header-artist')),
      );
      expect(title.style?.fontWeight, FontWeight.w500);
      expect(artist.style?.fontSize, lessThan(title.style!.fontSize!));
      expect(artist.style?.fontWeight, FontWeight.w400);

      expect(find.byKey(const ValueKey('player-source-chip')), findsNothing);
      expect(find.byKey(const ValueKey('player-quality-tag')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('player-cover-menu-button')));
      await _pumpUi(tester);

      expect(
        find.byKey(const ValueKey('player-cover-actions-sheet')),
        findsOneWidget,
      );
      expect(find.text('窄屏在线歌曲'), findsNWidgets(2));
      expect(find.text('高品质 320K · QQ'), findsOneWidget);
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('player-cover-action-download')),
            )
            .enabled,
        isTrue,
      );
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('player-cover-action-playlist')),
            )
            .enabled,
        isTrue,
      );

      await tester.tap(
        find.byKey(const ValueKey('player-cover-action-playlist')),
      );
      await _pumpUi(tester);

      expect(find.text('添加歌曲到'), findsOneWidget);
      await tester.tap(find.text('在线收藏'));
      await _pumpUi(tester);

      final storedPlaylist = container
          .read(localPlaylistsProvider)
          .singleWhere((candidate) => candidate.id == playlist.id);
      expect(storedPlaylist.tracks, hasLength(1));
      final storedTrack = storedPlaylist.tracks.single;
      expect(storedTrack.musicId, music.id);
      expect(storedTrack.name, music.name);
      expect(storedTrack.singer, music.singer);
      expect(storedTrack.albumName, music.albumName);
      expect(storedTrack.source, music.source);
      expect(storedTrack.qualityCode, music.bestQuality.code);
      expect(storedTrack.localPath, isNull);
      expect(storedTrack.picUrl, music.meta.picUrl);
      expect(storedTrack.musicJson, music.toJson());
      expect(storedTrack.musicInfo?.toJson(), music.toJson());

      await tester.tap(find.byKey(const ValueKey('player-cover-menu-button')));
      await _pumpUi(tester);

      await tester.tap(
        find.byKey(const ValueKey('player-cover-action-quality')),
      );
      await _pumpUi(tester);

      expect(
        find.byKey(const ValueKey('player-quality-sheet')),
        findsOneWidget,
      );
      expect(find.text('文件大小 9.48 MB'), findsOneWidget);
      expect(find.text('文件大小未知'), findsNothing);
      expect(find.text('较高品质 192K'), findsNothing);
      expect(
        find.byKey(const ValueKey('player-quality-option-192k')),
        findsNothing,
      );
      expect(find.text('文件大小 3.82 MB'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('player-quality-option-128k')),
      );
      await _pumpUi(tester);

      expect(controller.switchedQuality, Quality.k128);
      expect(find.byKey(const ValueKey('player-quality-sheet')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact local player disables inapplicable cover actions', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: const PlayerTrack(
        id: 'local:test-song',
        kind: PlayerTrackKind.localFile,
        title: '窄屏本地歌曲',
        artist: '本地歌手',
        album: '本地专辑',
        sourceLabel: 'QQ',
        qualityLabel: 'FLAC',
        localPath: 'test-song.flac',
      ),
    );

    expect(find.text('窄屏本地歌曲'), findsOneWidget);
    expect(find.text('本地歌手'), findsOneWidget);
    expect(find.byKey(const ValueKey('player-quality-button')), findsNothing);
    expect(find.byKey(const ValueKey('player-source-chip')), findsNothing);
    expect(find.byKey(const ValueKey('player-quality-tag')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('player-cover-menu-button')));
    await _pumpUi(tester);
    expect(find.text('FLAC · 本地'), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('player-cover-action-download')),
          )
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('player-cover-action-quality')),
          )
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('player-cover-action-playlist')),
          )
          .enabled,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('cover page lyrics reuse the lyrics page view', (tester) async {
    const lyrics = KaraokeLyrics([
      KaraokeLyricLine(startMs: 0, endMs: 3000, text: '第一句歌词'),
      KaraokeLyricLine(startMs: 3000, endMs: 6000, text: '第二句歌词'),
      KaraokeLyricLine(startMs: 6000, endMs: 9000, text: '第三句歌词'),
      KaraokeLyricLine(startMs: 9000, endMs: 12000, text: '第四句歌词'),
    ]);
    final controller = await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: const PlayerTrack(
        id: 'tx:mini-lyrics',
        kind: PlayerTrackKind.remote,
        title: '迷你歌词测试',
        artist: '测试歌手',
        album: '测试专辑',
        sourceLabel: 'QQ',
        qualityLabel: '320k',
      ),
      lyrics: lyrics,
      position: const Duration(milliseconds: 3500),
    );

    final coverLyrics = find.byKey(const ValueKey('player-cover-lyrics'));
    expect(coverLyrics, findsOneWidget);
    final coverLyricsView = find.byKey(
      const ValueKey('player-cover-lyrics-view'),
    );
    expect(coverLyricsView, findsOneWidget);
    expect(
      tester.widget<KaraokeLyricsView>(coverLyricsView).showTranslation,
      isFalse,
    );
    expect(find.byType(KaraokeLineText), findsWidgets);
    expect(
      tester.getSize(coverLyrics).height,
      closeTo(kLyricFontSizeDefault * 0.8 * 1.75 * 3 + 12, 0.5),
    );
    // The pane sits under the album caption instead of covering it.
    expect(
      tester.getRect(coverLyrics).top,
      greaterThanOrEqualTo(tester.getRect(find.text('测试专辑')).bottom),
    );

    controller.setStateForTest(
      controller.state.copyWith(position: const Duration(milliseconds: 6500)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<KaraokeLyricsView>(coverLyricsView)
          .lyrics
          .lines
          .first
          .text,
      '第一句歌词',
    );

    final pageView = tester.widget<PageView>(
      find.byKey(const ValueKey('player-compact-pager')),
    );
    await tester.drag(
      find.byKey(const ValueKey('player-compact-pager')),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();
    expect(pageView.controller!.page, 1);
    expect(find.byType(KaraokeLyricsView), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cover menu switch hides the cover lyric pane immediately', (
    tester,
  ) async {
    const lyrics = KaraokeLyrics([
      KaraokeLyricLine(startMs: 0, endMs: 3000, text: '第一句歌词'),
      KaraokeLyricLine(startMs: 3000, endMs: 6000, text: '第二句歌词'),
      KaraokeLyricLine(startMs: 6000, endMs: 9000, text: '第三句歌词'),
    ]);
    await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: const PlayerTrack(
        id: 'tx:toggle-mini-lyrics',
        kind: PlayerTrackKind.remote,
        title: '开关测试',
        artist: '测试歌手',
        album: '测试专辑',
        sourceLabel: 'QQ',
        qualityLabel: '320k',
      ),
      lyrics: lyrics,
    );
    expect(find.byKey(const ValueKey('player-cover-lyrics')), findsOneWidget);
    final liftedCoverTop = tester.getTopLeft(
      find.byKey(const ValueKey('player-cover-menu-button')),
    );

    await tester.tap(find.byKey(const ValueKey('player-cover-menu-button')));
    await _pumpUi(tester);
    await tester.tap(
      find.byKey(const ValueKey('player-cover-action-mini-lyrics-switch')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('player-cover-lyrics')), findsNothing);
    final centeredCoverTop = tester.getTopLeft(
      find.byKey(const ValueKey('player-cover-menu-button')),
    );
    expect(centeredCoverTop.dy, greaterThan(liftedCoverTop.dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('lyric size pill opens a live style sheet', (tester) async {
    await _pumpLyricsPanel(
      tester,
      const PlayerState(
        lyrics: KaraokeLyrics([
          KaraokeLyricLine(startMs: 0, endMs: 3000, text: '第一句歌词'),
          KaraokeLyricLine(startMs: 3000, endMs: 6000, text: '第二句歌词'),
        ]),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LyricsPanel)),
    );
    await container
        .read(settingsProvider.notifier)
        .setLyricFontStyle(
          weight: kLyricFontWeightDefault,
          size: 40,
          translationWeight: kLyricTranslationFontWeightDefault,
          translationSize: kLyricTranslationFontSizeDefault,
        );
    await _pumpUi(tester);
    expect(container.read(settingsProvider).lyricFontSize, 40);

    await tester.tap(find.byKey(const ValueKey('player-lyric-size-button')));
    await _pumpUi(tester);
    expect(
      find.byKey(const ValueKey('player-lyric-style-sheet')),
      findsOneWidget,
    );
    expect(find.text('歌词字号'), findsOneWidget);
    expect(find.byType(SettingsNumberControl), findsNWidgets(4));

    await tester.tap(find.text('重置'));
    await _pumpUi(tester);
    expect(
      container.read(settingsProvider).lyricFontSize,
      kLyricFontSizeDefault,
    );

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('player-lyric-style-sheet')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('late audio readiness does not remount loaded lyrics', (
    tester,
  ) async {
    const lyrics = KaraokeLyrics([
      KaraokeLyricLine(startMs: 0, endMs: 3000, text: '已经加载的歌词'),
    ]);
    final controller = await _pumpLyricsPanel(
      tester,
      const PlayerState(lyrics: lyrics),
    );
    final lyricsView = tester.element(find.byType(KaraokeLyricsView));

    controller.setStateForTest(
      const PlayerState(
        track: PlayerTrack(
          id: 'tx:late-audio:remote',
          kind: PlayerTrackKind.remote,
          title: '高音质歌曲',
          artist: '测试歌手',
          album: '测试专辑',
          sourceLabel: 'QQ',
          qualityLabel: 'hires',
          remoteUrl: 'https://audio.example/late.flac',
        ),
        lyrics: lyrics,
        duration: Duration(minutes: 4),
      ),
    );
    await tester.pump();

    expect(find.byType(KaraokeLyricsView), findsOneWidget);
    expect(tester.element(find.byType(KaraokeLyricsView)), same(lyricsView));
    expect(tester.takeException(), isNull);
  });

  testWidgets('lyrics keep their fade but drop it before a pager drag', (
    tester,
  ) async {
    const lyrics = KaraokeLyrics([
      KaraokeLyricLine(startMs: 0, endMs: 3000, text: '第一句歌词'),
      KaraokeLyricLine(startMs: 3000, endMs: 6000, text: '第二句歌词'),
      KaraokeLyricLine(startMs: 6000, endMs: 9000, text: '第三句歌词'),
    ]);
    final controller = await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: const PlayerTrack(
        id: 'tx:lyrics-edge-fade',
        kind: PlayerTrackKind.remote,
        title: '歌词边缘测试',
        artist: '测试歌手',
        album: '测试专辑',
        sourceLabel: 'QQ',
        qualityLabel: '320k',
        remoteUrl: 'https://audio.example/lyrics-edge-fade.mp3',
      ),
      lyrics: lyrics,
    );
    await tester.drag(
      find.byKey(const ValueKey('player-compact-pager')),
      const Offset(-360, 0),
    );
    await _pumpUi(tester);

    final viewport = find.byType(KaraokeLyricsView);
    final edgeFade = find.byKey(const ValueKey('karaoke-lyrics-edge-fade'));
    final list = find.byKey(const ValueKey('karaoke-lyrics-list'));
    expect(
      find.byKey(const ValueKey('player-compact-lyrics-clip')),
      findsOneWidget,
    );
    expect(edgeFade, findsOneWidget);
    expect(list, findsOneWidget);
    expect(tester.getRect(edgeFade), tester.getRect(viewport));
    expect(tester.getRect(list), tester.getRect(viewport));
    final fadeRenderObject = tester.renderObject<RenderBox>(edgeFade);
    final lyricsListElement = tester.element(list);
    expect(
      tester.widget<LyricsPanel>(find.byType(LyricsPanel)).edgeFadeEnabled,
      isTrue,
    );
    expect(
      find.descendant(of: viewport, matching: find.byType(ImageFiltered)),
      findsWidgets,
    );

    final gesture = await tester.startGesture(tester.getCenter(viewport));
    await tester.pump();
    expect(edgeFade, findsOneWidget);
    await gesture.moveBy(const Offset(8, 0));
    await tester.pump();
    expect(edgeFade, findsOneWidget);
    expect(tester.renderObject<RenderBox>(edgeFade), same(fadeRenderObject));
    expect(tester.element(list), same(lyricsListElement));
    expect(
      tester.widget<LyricsPanel>(find.byType(LyricsPanel)).edgeFadeEnabled,
      isFalse,
    );
    await gesture.moveBy(const Offset(72, 0));
    await tester.pump();
    expect(tester.element(list), same(lyricsListElement));
    expect(
      tester.widget<LyricsPanel>(find.byType(LyricsPanel)).edgeFadeEnabled,
      isFalse,
    );
    controller.setStateForTest(
      controller.state.copyWith(position: const Duration(milliseconds: 3500)),
    );
    await tester.pump();
    expect(tester.element(list), same(lyricsListElement));
    expect(
      tester.widget<LyricsPanel>(find.byType(LyricsPanel)).edgeFadeEnabled,
      isFalse,
    );
    await gesture.up();
    await _pumpUi(tester);
    expect(edgeFade, findsOneWidget);
    expect(tester.renderObject<RenderBox>(edgeFade), same(fadeRenderObject));
    expect(tester.element(list), same(lyricsListElement));
    expect(
      tester.widget<LyricsPanel>(find.byType(LyricsPanel)).edgeFadeEnabled,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'lyrics keep the current-line scroll position across page swipes',
    (tester) async {
      final lyrics = _timedLyrics(14);
      await _pumpPlayer(
        tester,
        size: const Size(390, 844),
        track: const PlayerTrack(
          id: 'tx:lyrics-page-position',
          kind: PlayerTrackKind.remote,
          title: '歌词位置测试',
          artist: '测试歌手',
          album: '测试专辑',
          sourceLabel: 'QQ',
          qualityLabel: '320k',
        ),
        lyrics: lyrics,
        position: const Duration(milliseconds: 18000),
      );
      final pager = find.byKey(const ValueKey('player-compact-pager'));
      await tester.drag(pager, const Offset(-360, 0));
      await _pumpUi(tester);

      final scrollPosition = _lyricsScrollPosition(tester);
      final initialOffset = scrollPosition.pixels;
      expect(initialOffset, greaterThan(0));

      await tester.drag(pager, const Offset(360, 0));
      await _pumpUi(tester);
      await tester.drag(pager, const Offset(-360, 0));
      await _pumpUi(tester);

      final restoredPosition = _lyricsScrollPosition(tester);
      expect(restoredPosition.pixels, greaterThan(0));
      expect(restoredPosition.pixels, closeTo(initialOffset, 0.01));
      expect(
        find.byKey(const ValueKey('lyric-focus-scale-18000')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('lyric stagger keeps the relocated scroll offset stable', (
    tester,
  ) async {
    final lyrics = _timedLyrics(14);
    final controller = await _pumpLyricsPanel(
      tester,
      PlayerState(
        lyrics: lyrics,
        position: const Duration(milliseconds: 15000),
      ),
    );
    final scrollPosition = _lyricsScrollPosition(tester);
    final initialOffset = scrollPosition.pixels;

    expect(_lyricFocusScale(tester, 15000), closeTo(1, 0.0001));
    expect(_lyricFocusScale(tester, 18000), closeTo(0.95, 0.0001));

    controller.setStateForTest(
      controller.state.copyWith(position: const Duration(milliseconds: 18000)),
    );
    await tester.pump();
    await tester.pump();

    final relocatedOffset = scrollPosition.pixels;
    expect(relocatedOffset, isNot(closeTo(initialOffset, 0.01)));

    for (final interval in const [
      Duration(milliseconds: 100),
      Duration(milliseconds: 150),
      Duration(milliseconds: 200),
      Duration(milliseconds: 250),
    ]) {
      await tester.pump(interval);
      expect(scrollPosition.pixels, closeTo(relocatedOffset, 0.001));
    }

    expect(_lyricFocusScale(tester, 15000), closeTo(0.95, 0.0001));
    expect(_lyricFocusScale(tester, 18000), closeTo(1, 0.0001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('word-timed lyric keeps its layout height across focus changes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    const longLine = KaraokeLyricLine(
      startMs: 3000,
      endMs: 6000,
      text: '春风穿过旧山河星光落在长街上我们走向晨曦里月色停在窗台前',
      words: [
        KaraokeWordTiming(text: '春风穿过旧山河', startMs: 3000, endMs: 3700),
        KaraokeWordTiming(text: '星光落在长街上', startMs: 3700, endMs: 4400),
        KaraokeWordTiming(text: '我们走向晨曦里', startMs: 4400, endMs: 5100),
        KaraokeWordTiming(text: '月色停在窗台前', startMs: 5100, endMs: 5800),
      ],
    );
    const lyrics = KaraokeLyrics([
      KaraokeLyricLine(startMs: 0, endMs: 3000, text: '前一句'),
      longLine,
      KaraokeLyricLine(startMs: 6000, endMs: 9000, text: '后一句'),
    ]);
    final controller = await _pumpLyricsPanel(
      tester,
      const PlayerState(lyrics: lyrics),
    );
    final longLineFinder = find.byKey(const ValueKey('lyric-stagger-3000'));
    final inactiveHeight = tester.getSize(longLineFinder).height;
    expect(inactiveHeight, greaterThan(100));

    controller.setStateForTest(
      controller.state.copyWith(position: const Duration(milliseconds: 3500)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(
      tester.getSize(longLineFinder).height,
      closeTo(inactiveHeight, 0.001),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('bilingual sweeps keep source rests and resume at a seek', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 680);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const lyrics = KaraokeLyrics([
      KaraokeLyricLine(
        startMs: 0,
        endMs: 4000,
        text: 'Coming close',
        translation: '这次请慢慢靠近我 👩🏽‍🚀 再陪我走过长长的路',
        words: [
          KaraokeWordTiming(text: 'Coming ', startMs: 500, endMs: 1000),
          KaraokeWordTiming(text: 'close', startMs: 2000, endMs: 3500),
        ],
      ),
      KaraokeLyricLine(
        startMs: 4000,
        endMs: 8000,
        text: 'No word clock',
        translation: '只有行时间',
      ),
      KaraokeLyricLine(
        startMs: 8000,
        endMs: 12000,
        text: 'Last line',
        translation: '真实词轴',
        translationWords: [
          KaraokeWordTiming(text: '真实词轴', startMs: 10000, endMs: 11000),
        ],
      ),
    ]);
    final controller = await _pumpLyricsPanel(
      tester,
      const PlayerState(lyrics: lyrics),
    );
    double progress(bool translation) => tester
        .state<KaraokeLineTextState>(
          find.byWidgetPredicate(
            (w) =>
                w is KaraokeLineText &&
                w.active &&
                w.translation == translation,
          ),
        )
        .debugSweepProgress;
    Future<void> seek(int ms) async {
      controller.setStateForTest(
        controller.state.copyWith(position: Duration(milliseconds: ms)),
      );
      await tester.pump();
    }

    expect(progress(true), 0);
    await seek(1000);
    final held = progress(false);
    expect(progress(true), closeTo(.25, .001));
    await seek(1900);
    expect(progress(false), held);
    expect(progress(true), closeTo(.25, .001));
    await seek(2750);
    expect(progress(true), closeTo(.625, .001));
    await seek(750);
    expect(progress(true), closeTo(.125, .001));
    await seek(6000);
    expect(progress(false), closeTo(.5, .001));
    expect(progress(true), closeTo(.5, .001));
    await seek(9000);
    expect(progress(false), closeTo(.25, .001));
    expect(progress(true), 0);
    await seek(10500);
    expect(progress(true), closeTo(.5, .001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('untimed lyrics remain readable without a false seek target', (
    tester,
  ) async {
    final lyrics = KaraokeLyricsParser.parse(
      const LyricInfo(
        lyric: 'First untimed line\nSecond untimed line',
        tlyric: '第一行\n第二行',
      ),
    );
    final controller = await _pumpLyricsPanel(
      tester,
      PlayerState(lyrics: lyrics, position: const Duration(seconds: 25)),
    );
    expect(find.text('First untimed line'), findsOneWidget);
    expect(find.text('第二行'), findsOneWidget);
    expect(find.byType(KaraokeLineText), findsNothing);
    await tester.tap(find.text('第二行'));
    await tester.pump();
    expect(controller.state.position, const Duration(seconds: 25));
    expect(tester.takeException(), isNull);
  });

  testWidgets('word progress keeps elapsed time when a new line activates', (
    tester,
  ) async {
    const lyrics = KaraokeLyrics([
      KaraokeLyricLine(
        startMs: 0,
        endMs: 1000,
        text: '前一句',
        words: [KaraokeWordTiming(text: '前一句', startMs: 0, endMs: 1000)],
      ),
      KaraokeLyricLine(
        startMs: 1000,
        endMs: 3000,
        text: '新一句',
        words: [KaraokeWordTiming(text: '新一句', startMs: 1000, endMs: 2000)],
      ),
    ]);
    final controller = await _pumpLyricsPanel(
      tester,
      const PlayerState(lyrics: lyrics, position: Duration(milliseconds: 990)),
    );

    controller.setStateForTest(controller.state.copyWith(playing: true));
    await tester.pump();
    // No position anchor is published here. The line-advance timer activates
    // the second row from wall-clock elapsed time after the 990 ms anchor.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(_activeWordProgress(tester, 1000), greaterThan(0.02));
    expect(tester.takeException(), isNull);
  });

  testWidgets('word progress pauses while buffering and resumes afterwards', (
    tester,
  ) async {
    const lyrics = KaraokeLyrics([
      KaraokeLyricLine(
        startMs: 0,
        endMs: 6000,
        text: '缓冲中的逐字歌词',
        words: [KaraokeWordTiming(text: '缓冲中的逐字歌词', startMs: 0, endMs: 5000)],
      ),
    ]);
    final controller = await _pumpLyricsPanel(
      tester,
      const PlayerState(lyrics: lyrics, position: Duration(milliseconds: 1000)),
    );

    controller.setStateForTest(controller.state.copyWith(playing: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    controller.setStateForTest(
      controller.state.copyWith(
        position: const Duration(milliseconds: 1200),
        processingState: PlayerProcessingState.buffering,
      ),
    );
    await tester.pump();

    final bufferedProgress = _activeWordProgress(tester, 0);
    expect(bufferedProgress, closeTo(0.24, 0.001));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(_activeWordProgress(tester, 0), closeTo(bufferedProgress, 0.0001));

    controller.setStateForTest(
      controller.state.copyWith(processingState: PlayerProcessingState.ready),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(
      _activeWordProgress(tester, 0),
      greaterThan(bufferedProgress + 0.01),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'phone landscape keeps the cover and album above compact controls',
    (tester) async {
      const size = Size(932, 430);
      tester.view.padding = const FakeViewPadding(
        left: 59,
        right: 59,
        bottom: 21,
      );
      addTearDown(tester.view.resetPadding);
      SharedPreferences.setMockInitialValues({
        'square_album_cover_enabled': true,
      });
      final player = await _pumpPlayer(
        tester,
        size: size,
        track: const PlayerTrack(
          id: 'tx:landscape',
          kind: PlayerTrackKind.remote,
          title: '横屏歌曲',
          artist: '横屏歌手',
          album: '横屏专辑',
          sourceLabel: 'QQ',
          qualityLabel: 'FLAC',
        ),
        lyrics: _timedLyrics(4),
      );

      final pagerFinder = find.byKey(const ValueKey('player-compact-pager'));
      final pager = tester.getRect(pagerFinder);
      final cover = tester.getRect(
        find.byKey(const ValueKey('player-cover-menu-button')),
      );
      final album = tester.getRect(find.text('横屏专辑'));
      final coverLyrics = tester.getRect(
        find.byKey(const ValueKey('player-cover-lyrics')),
      );
      expect(cover.width, closeTo(cover.height, 0.01));
      expect(cover.top, greaterThanOrEqualTo(pager.top));
      expect(size.width - cover.right, greaterThan(0));
      // The timer and library buttons moved out of the player header.
      expect(
        find.byKey(const ValueKey('player-sleep-timer-button')),
        findsNothing,
      );
      expect(find.byTooltip('本地歌曲'), findsNothing);

      expect(
        tester
            .widget<SpinningCoverArt>(find.byType(SpinningCoverArt))
            .boxShadow,
        isNull,
      );
      expect(coverLyrics.right, lessThan(cover.left));
      expect(album.center.dx, closeTo(cover.center.dx, 0.01));
      expect(album.top - cover.bottom, closeTo(8, 0.01));
      expect(album.bottom, lessThanOrEqualTo(pager.bottom));
      expect(
        pager.bottom,
        lessThanOrEqualTo(tester.getTopLeft(find.byType(Slider)).dy),
      );

      final icons = [
        Icons.format_list_numbered_rounded,
        Icons.skip_previous_rounded,
        Icons.play_arrow_rounded,
        Icons.skip_next_rounded,
        Icons.queue_music_rounded,
      ];
      final targets = <Rect>[];
      for (final icon in icons) {
        final glyph = find.byIcon(icon);
        final button = find
            .ancestor(of: glyph, matching: find.byType(InkWell))
            .first;
        final rect = tester.getRect(button);
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
        targets.add(rect);
      }
      expect(targets.last.right - targets.first.left, lessThanOrEqualTo(312));
      expect(targets.last.bottom, lessThanOrEqualTo(size.height - 21));
      expect(
        tester.widget<Icon>(find.byIcon(Icons.play_arrow_rounded)).size,
        40,
      );

      await tester.drag(pagerFinder, const Offset(-700, 0));
      await _pumpUi(tester);
      final controller = tester.widget<PageView>(pagerFinder).controller!;
      expect(controller.page, closeTo(1, 0.01));
      controller.jumpToPage(0);

      // Short landscape windows can have a cutout on either side.
      const shortSize = Size(667, 375);
      tester.view.physicalSize = shortSize;
      for (final rightInset in [0.0, 32.0]) {
        tester.view.padding = FakeViewPadding(
          left: 32 - rightInset,
          right: rightInset,
          bottom: 16,
        );
        await _pumpUi(tester);
        final shortCover = tester.getRect(
          find.byKey(const ValueKey('player-cover-menu-button')),
        );
        final shortCaption = tester.getRect(find.text('横屏专辑'));
        final shortLyrics = tester.getRect(
          find.byKey(const ValueKey('player-cover-lyrics')),
        );
        expect(
          shortSize.width - rightInset - shortCover.right,
          greaterThan(0),
        );
        expect(shortCover.width, closeTo(shortCover.height, 0.01));
        expect(shortLyrics.right, lessThan(shortCover.left));
        expect(shortCaption.center.dx, closeTo(shortCover.center.dx, 0.01));
        expect(shortCaption.top - shortCover.bottom, closeTo(8, 0.01));
        expect(
          shortCaption.bottom,
          lessThanOrEqualTo(tester.getRect(pagerFinder).bottom),
        );
      }
      const longAlbum = '这张专辑的名称很长，横屏时仍应位于右侧安全区内并在封面正下方居中';
      player.setStateForTest(
        player.state.copyWith(
          track: const PlayerTrack(
            id: 'tx:long-album',
            kind: PlayerTrackKind.remote,
            title: '横屏歌曲',
            artist: '横屏歌手',
            album: longAlbum,
            sourceLabel: 'QQ',
            qualityLabel: 'FLAC',
          ),
        ),
      );
      await _pumpUi(tester);
      final longTitle = tester.getRect(find.text(longAlbum));
      final longCover = tester.getRect(
        find.byKey(const ValueKey('player-cover-menu-button')),
      );
      expect(longTitle.right, lessThanOrEqualTo(shortSize.width - 32));
      expect(longTitle.center.dx, closeTo(longCover.center.dx, 0.01));
      expect(longTitle.top - longCover.bottom, closeTo(8, 0.01));
      expect(
        tester.widget<Text>(find.text(longAlbum)).overflow,
        TextOverflow.ellipsis,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wide player renders album and lyrics together without pager', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      size: const Size(1024, 600),
      carPadModeEnabled: true,
      track: const PlayerTrack(
        id: 'wy:wide-song',
        kind: PlayerTrackKind.remote,
        title: '宽屏歌曲',
        artist: '宽屏歌手',
        album: '宽屏专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/wide-song.flac',
      ),
      lyrics: const KaraokeLyrics([
        KaraokeLyricLine(startMs: 0, endMs: 3000, text: '宽屏第一句'),
        KaraokeLyricLine(startMs: 3000, endMs: 6000, text: '宽屏第二句'),
        KaraokeLyricLine(startMs: 6000, endMs: 9000, text: '宽屏第三句'),
      ]),
    );

    expect(find.byKey(const ValueKey('player-wide-layout')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-compact-pager')), findsNothing);
    expect(find.byKey(const ValueKey('player-cover-lyrics')), findsNothing);
    expect(find.byType(PageView), findsNothing);
    expect(find.byType(VerticalDivider), findsNothing);
    expect(find.byType(AlbumPage), findsOneWidget);
    expect(find.byType(LyricsPanel), findsOneWidget);
    expect(find.text('宽屏歌曲'), findsOneWidget);
    expect(find.text('宽屏歌手'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('player-cover-menu-button')));
    await _pumpUi(tester);
    expect(
      find.byKey(const ValueKey('player-cover-actions-sheet')),
      findsOneWidget,
    );
    expect(find.text('仅在手机播放封面页显示'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _RouterHarness {
  const _RouterHarness({required this.router});

  final GoRouter router;
}

class _SeededPlayerController extends PlayerController {
  _SeededPlayerController(
    super.ref,
    PlayerState initialState, {
    this.seededCurrentMusic,
  }) {
    state = initialState;
  }

  Quality? switchedQuality;
  final MusicInfo? seededCurrentMusic;

  @override
  MusicInfo? get currentMusic => seededCurrentMusic ?? super.currentMusic;

  void setStateForTest(PlayerState next) => state = next;

  @override
  Future<bool> switchQuality(Quality quality) async {
    switchedQuality = quality;
    return true;
  }
}

Future<_SeededPlayerController> _pumpLyricsPanel(
  WidgetTester tester,
  PlayerState initialState,
) async {
  final preferences = await SharedPreferences.getInstance();
  final audioHandler = PlayerAudioHandler();
  addTearDown(() => unawaited(audioHandler.disposeHandler()));
  late _SeededPlayerController controller;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        playerAudioHandlerProvider.overrideWithValue(audioHandler),
        playerControllerProvider.overrideWith(
          (ref) => controller = _SeededPlayerController(ref, initialState),
        ),
      ],
      child: MaterialApp(
        theme: _theme(),
        home: const Scaffold(body: LyricsPanel()),
      ),
    ),
  );
  await _pumpUi(tester);
  controller.setStateForTest(initialState);
  await _pumpUi(tester);
  return controller;
}

Future<_RouterHarness> _pumpRoutedApp(
  WidgetTester tester, {
  required String initialLocation,
}) async {
  final preferences = await SharedPreferences.getInstance();
  final audioHandler = PlayerAudioHandler();
  final router = createAppRouter(initialLocation: initialLocation);
  addTearDown(router.dispose);
  addTearDown(() => unawaited(audioHandler.disposeHandler()));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        playerAudioHandlerProvider.overrideWithValue(audioHandler),
        playerControllerProvider.overrideWith(
          (ref) => _SeededPlayerController(ref, const PlayerState()),
        ),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        routerConfig: router,
      ),
    ),
  );
  await _pumpUi(tester);
  return _RouterHarness(router: router);
}

Future<_SeededPlayerController> _pumpPlayer(
  WidgetTester tester, {
  required Size size,
  required PlayerTrack track,
  KaraokeLyrics lyrics = const KaraokeLyrics([]),
  Duration position = Duration.zero,
  MusicInfo? currentMusic,
  bool carPadModeEnabled = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });

  final preferences = await SharedPreferences.getInstance();
  if (carPadModeEnabled) {
    await preferences.setBool('car_pad_mode_enabled', true);
  }
  final audioHandler = PlayerAudioHandler();
  addTearDown(() => unawaited(audioHandler.disposeHandler()));
  final initialState = PlayerState(
    track: track,
    duration: const Duration(minutes: 3),
    lyrics: lyrics,
    position: position,
  );
  late _SeededPlayerController controller;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        playerAudioHandlerProvider.overrideWithValue(audioHandler),
        playerControllerProvider.overrideWith(
          (ref) => controller = _SeededPlayerController(
            ref,
            initialState,
            seededCurrentMusic: currentMusic,
          ),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        builder: (context, child) =>
            AppToastOverlay(child: child ?? const SizedBox.shrink()),
        home: PlayerPage(
          returnLocation: '/songs',
          progress: const AlwaysStoppedAnimation<double>(1),
          active: true,
          onDismissRequested: _ignoreDismiss,
        ),
      ),
    ),
  );
  await _pumpUi(tester);
  controller.setStateForTest(initialState);
  await _pumpUi(tester);
  return controller;
}

KaraokeLyrics _timedLyrics(int count) {
  return KaraokeLyrics([
    for (var index = 0; index < count; index++)
      KaraokeLyricLine(
        startMs: index * 3000,
        endMs: (index + 1) * 3000,
        text: '第${index + 1}句歌词用于测试平稳切换',
      ),
  ]);
}

ScrollPosition _lyricsScrollPosition(WidgetTester tester) {
  final scrollable = find.descendant(
    of: find.byKey(const ValueKey('karaoke-lyrics-list')),
    matching: find.byType(Scrollable),
  );
  return tester.state<ScrollableState>(scrollable).position;
}

double _lyricFocusScale(WidgetTester tester, int startMs) {
  final transform = tester.widget<Transform>(
    find.byKey(ValueKey('lyric-focus-scale-$startMs')),
  );
  return transform.transform.storage.first;
}

double _activeWordProgress(WidgetTester tester, int lineStartMs) {
  final lyricText = find.descendant(
    of: find.byKey(ValueKey('lyric-focus-scale-$lineStartMs')),
    matching: find.byType(KaraokeLineText),
  );
  final lyric = tester.widget<KaraokeLineText>(lyricText);
  expect(lyric.active, isTrue);
  final word = lyric.line.words.single;
  final positionMs = tester
      .state<KaraokeLineTextState>(lyricText)
      .debugPlaybackPositionMs;
  return ((positionMs - word.startMs) / (word.endMs - word.startMs)).clamp(
    0.0,
    1.0,
  );
}

ThemeData _theme() {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
  );
}

void _ignoreDismiss([String? target]) {}

Future<void> _pumpUi(WidgetTester tester) async {
  for (var index = 0; index < 12; index++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

MusicInfo _remoteMusic() => MusicInfo.fromJson({
  'id': 'remote-song',
  'name': '窄屏在线歌曲',
  'singer': '不应在封面下重复的歌手',
  'source': MusicSource.tx.code,
  'meta': {
    'songId': 'remote-song',
    'albumName': '测试专辑',
    'qualitys': [
      {'type': Quality.k320.code, 'size': '9.48 MB'},
      {'type': Quality.k128.code, 'size': '3.82 MB'},
    ],
  },
});
