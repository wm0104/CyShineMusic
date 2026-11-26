import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:bass_player/bass_player.dart' as bass;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/api/music_api.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/lyric_info.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/models/music_url.dart';
import 'package:cy_shine_music/core/music_sources/music_source_models.dart';
import 'package:cy_shine_music/core/music_sources/music_source_runtime.dart';
import 'package:cy_shine_music/core/music_sources/music_url_resolver.dart';
import 'package:cy_shine_music/core/services/app_logger.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/player/player_audio_handler.dart';
import 'package:cy_shine_music/features/player/live_activity_service.dart';
import 'package:cy_shine_music/features/player/player_controller.dart';
import 'package:cy_shine_music/features/downloads/download_history_entry.dart';
import 'package:cy_shine_music/features/player/player_session_snapshot.dart';
import 'package:cy_shine_music/features/player/player_session_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('player track keeps source quality sizes and canonical Hi-Res data', () {
    final music = MusicInfo(
      id: 'sized-song',
      name: 'Sized Song',
      singer: 'Singer',
      source: MusicSource.kw,
      interval: '03:00',
      meta: const MusicMeta(
        songId: 'sized-song',
        albumName: 'Album',
        qualitys: [
          QualityOption(type: Quality.flac24bit, size: '48.20 MB'),
          QualityOption(type: Quality.flac, size: '24.10 MB'),
        ],
        raw: {},
      ),
      raw: const {},
    );

    final track = PlayerTrack.fromMusic(
      music: music,
      quality: Quality.hires,
      url: 'https://audio.test/sized-song.flac',
      coverUrl: null,
      availableQualities: const [
        Quality.hires,
        Quality.flac24bit,
        Quality.flac,
        Quality.k320,
      ],
    );

    expect(track.availableQualities, [
      Quality.hires,
      Quality.flac,
      Quality.k320,
    ]);
    expect(track.availableQualityOptions[0].type, Quality.hires);
    expect(track.availableQualityOptions[0].size, '48.20 MB');
    expect(track.availableQualityOptions[1].size, '24.10 MB');
    expect(track.availableQualityOptions[2].size, isNull);
  });

  test(
    'audio load failure falls back without publishing an error state',
    () async {
      final harness = await _Harness.create(loadFailures: 1);
      addTearDown(harness.dispose);
      final errors = <String>[];
      final subscription = harness.container.listen<PlayerState>(
        playerControllerProvider,
        (_, next) {
          if (next.error != null) errors.add(next.error!);
        },
      );
      addTearDown(subscription.close);

      await harness.controller.playFromMusic(_music());
      final state = harness.container.read(playerControllerProvider);

      expect(harness.audio.loadedUris, [
        Uri.parse('https://audio.test/first.mp3'),
        Uri.parse('https://audio.test/second.mp3'),
      ]);
      expect(harness.resolver.attemptedIds, ['first', 'second']);
      expect(state.loading, isFalse);
      expect(state.error, isNull);
      expect(state.track?.remoteUrl, 'https://audio.test/second.mp3');
      expect(harness.audio.failTransitionCount, 0);
      expect(errors, isEmpty);
    },
  );

  test('NetEase system media artwork carries the required headers', () async {
    final harness = await _Harness.create(loadFailures: 0);
    addTearDown(harness.dispose);

    await harness.controller.playFromMusic(_neteaseMusic());

    final item = harness.audio.currentMediaItem;
    expect(
      item?.artUri.toString(),
      'https://p1.music.126.net/test/cover.jpg?param=500y500',
    );
    expect(item?.artHeaders, containsPair('Referer', 'https://music.163.com/'));
    expect(item?.artHeaders, contains('User-Agent'));
  });

  test('iOS Widget sync follows play, pause, track switch and stop', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('cy_shine_music/live_activity');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'isSupported') calls.add(call);
      return call.method == 'end' ? null : true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final harness = await _Harness.create(loadFailures: 0);
    addTearDown(harness.dispose);
    await harness.container.read(liveActivityProvider).initialize();
    harness.container.read(liveActivitySyncProvider);
    await harness.controller.playFromMusic(_music());
    expect(
      harness.audio.playbackState.value.processingState,
      AudioProcessingState.ready,
      reason: 'queue metadata must not replay idle and cancel the first Widget sync',
    );
    await _waitUntil(() => calls.isNotEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(calls.first.method, 'start');
    expect(calls.first.arguments, containsPair('title', 'Test Song'));
    calls.clear();

    final playing = PlaybackState(
      processingState: AudioProcessingState.ready,
      playing: true,
      updatePosition: const Duration(seconds: 17),
    );
    harness.audio.playbackState.add(playing);
    await _waitUntil(() => calls.isNotEmpty);
    expect(calls.single.method, 'update');
    expect(calls.single.arguments, containsPair('title', 'Test Song'));
    expect(calls.single.arguments, containsPair('playing', true));

    harness.audio.playbackState.add(playing.copyWith(playing: false));
    await _waitUntil(() => calls.length == 2);
    expect(calls.last.method, 'update');
    expect(calls.last.arguments, containsPair('playing', false));

    // The legacy end/start methods now only mark the Widget stopped and
    // synchronize the next track; they do not represent ActivityKit activity.
    final loadGate = Completer<void>();
    harness.api.coverUrl = 'http://p1.music.126.net/test/cover.jpg';
    harness.audio.loadGate = loadGate;
    final switching = harness.controller.playFromMusic(_neteaseMusic());
    await _waitUntil(() => harness.audio.loadedUris.length == 2);
    final transition = harness.container.read(playerControllerProvider);
    expect(transition.track, isNull);
    expect(transition.loading, isTrue);
    harness.audio.playbackState.add(
      PlaybackState(processingState: AudioProcessingState.loading),
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'end');
    calls.clear();

    loadGate.complete();
    await switching;
    harness.audio.playbackState.add(playing);
    await _waitUntil(
      () => calls.isNotEmpty && calls.last.arguments is Map &&
          calls.last.arguments['title'] == 'NetEase Song' &&
          calls.last.arguments['playing'] == true,
    );
    expect(calls.first.method, 'start');
    expect(calls.first.arguments, containsPair('title', 'NetEase Song'));
    expect(calls.first.arguments, containsPair(
      'cover', 'https://p1.music.126.net/test/cover.jpg?param=512y512',
    ));
    expect(calls.first.arguments['headers'],
        containsPair('Referer', 'https://music.163.com/'));

    harness.audio.playbackState.add(PlaybackState());
    await _waitUntil(() => calls.last.method == 'end');
    // No metadata-clearing payload: native end keeps the last title/cover.
    expect(calls.last.arguments, isNull);
    final stoppedCount = calls.length;
    harness.audio.playbackState.add(PlaybackState());
    await Future<void>.delayed(Duration.zero);
    expect(calls, hasLength(stoppedCount));

    harness.audio.playbackState.add(playing);
    await _waitUntil(() => calls.length > stoppedCount);
    expect(calls.last.method, 'start');
    expect(calls.last.arguments, containsPair('title', 'NetEase Song'));
    expect(calls.last.arguments, containsPair('playing', true));
  });

  test('iOS player deep link remains pending until the app is ready', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('cy_shine_music/live_activity');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      channel.setMethodCallHandler(null);
    });
    final harness = await _Harness.create(loadFailures: 0);
    addTearDown(harness.dispose);
    final service = harness.container.read(liveActivityProvider);
    await service.initialize();

    Future<void> openPlayer() async {
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('openPlayer')),
        null,
      );
    }

    await openPlayer();
    var openCount = 0;
    service.onOpenPlayer = () async {
      if (service.takeOpenPlayerRequest()) openCount++;
    };
    await service.onOpenPlayer!();
    await service.onOpenPlayer!();
    expect(openCount, 1);

    await openPlayer();
    expect(openCount, 2);
  });

  test('iOS Widget sync publishes changed cover for the same track', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('cy_shine_music/live_activity');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'isSupported') calls.add(call);
      return call.method == 'end' ? null : true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final harness = await _Harness.create(loadFailures: 0);
    addTearDown(harness.dispose);
    final service = harness.container.read(liveActivityProvider);
    await harness.container.read(liveActivityProvider).initialize();
    harness.container.read(liveActivitySyncProvider);
    await harness.controller.playFromMusic(_music());
    expect(
      harness.audio.playbackState.value.processingState,
      AudioProcessingState.ready,
      reason: 'queue metadata must not replay idle and cancel the first Widget sync',
    );
    await _waitUntil(() => calls.isNotEmpty);
    harness.audio.playbackState.add(PlaybackState(
      processingState: AudioProcessingState.ready,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final trackId = calls.last.arguments['trackId'];
    calls.clear();

    harness.api.coverUrl = 'https://art.test/new-cover.jpg';
    expect(await harness.controller.switchQuality(Quality.k320), isTrue);
    await _waitUntil(() => calls.any((call) =>
        call.arguments is Map &&
        call.arguments['cover'] == 'https://art.test/new-cover.jpg'));
    expect(calls.last.method, 'update');
    expect(calls.last.arguments, containsPair('trackId', trackId));
    expect(calls.last.arguments, containsPair('title', 'Test Song'));
    expect(calls.last.arguments, containsPair('playing', false));

    final count = calls.length;
    service.publish(harness.container.read(playerControllerProvider));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, hasLength(count), reason: 'unchanged metadata is deduplicated');
  });

  test('iOS Widget stop wins while native sync reply is pending', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('cy_shine_music/live_activity');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final reply = Completer<bool>();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isSupported') return true;
      calls.add(call);
      if (call.method == 'start') return reply.future;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final harness = await _Harness.create(loadFailures: 0);
    addTearDown(harness.dispose);
    await harness.container.read(liveActivityProvider).initialize();
    harness.container.read(liveActivitySyncProvider);
    await harness.controller.playFromMusic(_music());
    expect(
      harness.audio.playbackState.value.processingState,
      AudioProcessingState.ready,
      reason: 'queue metadata must not replay idle and cancel the first Widget sync',
    );
    await _waitUntil(() => calls.isNotEmpty);
    expect(calls.first.method, 'start');

    harness.audio.playbackState.add(PlaybackState());
    await _waitUntil(() => calls.last.method == 'end');
    reply.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'end');
    expect(calls.where((call) => call.method == 'end'), hasLength(1));
  });

  test('all source load failures publish only the final error state', () async {
    final harness = await _Harness.create(loadFailures: 2);
    addTearDown(harness.dispose);
    final errors = <String>[];
    final subscription = harness.container.listen<PlayerState>(
      playerControllerProvider,
      (_, next) {
        if (next.error != null) errors.add(next.error!);
      },
    );
    addTearDown(subscription.close);

    await harness.controller.playFromMusic(_music());
    final state = harness.container.read(playerControllerProvider);

    expect(harness.audio.loadedUris, hasLength(2));
    expect(state.loading, isFalse);
    expect(state.track, isNull);
    expect(state.error, contains('所有已启用音源均无法播放'));
    expect(harness.audio.failTransitionCount, 1);
    expect(errors, hasLength(1));
  });

  test(
    'auto-play-on-startup resumes the persisted track automatically',
    () async {
      final snapshot = PlayerSessionSnapshot(
        track: PersistedPlayerTrack(
          id: 'kw:song-1:remote',
          kindCode: PersistedPlayerTrack.remoteKindCode,
          title: 'Test Song',
          artist: 'Test Singer',
          album: 'Test Album',
          sourceLabel: MusicSource.kw.label,
          qualityLabel: Quality.k128.code,
        ),
        music: _music(),
        qualityCode: Quality.k128.code,
      );
      SharedPreferences.setMockInitialValues({
        'auto_play_on_startup': true,
        playerSessionSnapshotStorageKey: jsonEncode(snapshot.toJson()),
      });

      final harness = await _Harness.create(loadFailures: 0);
      addTearDown(harness.dispose);

      await _waitUntil(() => harness.audio.playCount == 1);
      expect(harness.audio.playing, isTrue);
      expect(harness.container.read(playerControllerProvider).track, isNotNull);
    },
  );

  test('a playback error retries only sources not already attempted', () async {
    final harness = await _Harness.create(loadFailures: 0);
    addTearDown(harness.dispose);

    await harness.controller.playFromMusic(_music());
    expect(
      harness.container.read(playerControllerProvider).track?.remoteUrl,
      'https://audio.test/first.mp3',
    );

    harness.audio.emitError(
      const bass.BassPlayerException(code: 1, message: 'stream failed'),
    );
    await _waitUntil(() => harness.audio.loadedUris.length == 2);
    final state = harness.container.read(playerControllerProvider);

    expect(harness.audio.loadedUris, [
      Uri.parse('https://audio.test/first.mp3'),
      Uri.parse('https://audio.test/second.mp3'),
    ]);
    expect(state.error, isNull);
    expect(state.track?.remoteUrl, 'https://audio.test/second.mp3');
  });

  test(
    'sleep timer pauses without losing the track or restarting a paused song',
    () async {
      final harness = await _Harness.create(loadFailures: 0);
      addTearDown(harness.dispose);
      await harness.controller.playFromMusic(_music());
      await harness.controller.seek(const Duration(seconds: 23));
      final track = harness.container.read(playerControllerProvider).track;

      await harness.controller.pauseForSleepTimer();
      expect(harness.audio.playing, isFalse);
      expect(harness.audio.position, const Duration(seconds: 23));
      expect(harness.container.read(playerControllerProvider).track, track);
      await harness.controller.pauseForSleepTimer();
      expect(harness.audio.playCount, 1);
      expect(harness.audio.playing, isFalse);

      await harness.controller.toggle();
      expect(harness.audio.playing, isTrue);
    },
  );

  test('sleep timer prevents a pending load from autoplaying', () async {
    final harness = await _Harness.create(loadFailures: 0);
    addTearDown(harness.dispose);
    final gate = Completer<void>();
    harness.audio.loadGate = gate;
    final loading = harness.controller.playFromMusic(_music());
    await _waitUntil(() => harness.audio.loadedUris.isNotEmpty);

    await harness.controller.pauseForSleepTimer();
    gate.complete();
    await loading;
    final state = harness.container.read(playerControllerProvider);
    expect(state.loading, isFalse);
    expect(state.track, isNotNull);
    expect(state.playing, isFalse);
    expect(harness.audio.playCount, 0);

    await harness.controller.toggle();
    expect(harness.audio.playCount, 1);
  });

  test(
    'sleep timer blocks late completion and errors until playback resumes',
    () async {
      final harness = await _Harness.create(loadFailures: 0);
      addTearDown(harness.dispose);
      await harness.controller.playFromMusic(_music());
      await harness.audio.setRepeatMode(AudioServiceRepeatMode.one);
      await harness.controller.pauseForSleepTimer();
      harness.audio.emitPlaybackState(bass.BassProcessingState.completed);
      harness.audio.emitError(
        const bass.BassPlayerException(code: 2, message: 'late error'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(harness.audio.playCount, 1);
      expect(harness.audio.loadedUris, hasLength(1));

      await harness.controller.toggle();
      harness.audio.emitPlaybackState(bass.BassProcessingState.buffering);
      harness.audio.emitPlaybackState(bass.BassProcessingState.ready);
      harness.audio.emitPlaybackState(bass.BassProcessingState.completed);
      await _waitUntil(() => harness.audio.playCount == 3);
    },
  );

  test(
    'sleep timer prevents an in-flight stall recovery from resuming',
    () async {
      final harness = await _Harness.create(
        loadFailures: 0,
        stallRecoveryDelay: const Duration(milliseconds: 20),
      );
      addTearDown(harness.dispose);
      await harness.controller.playFromMusic(_music());
      final gate = Completer<void>();
      harness.audio.pauseGate = gate;
      harness.audio.emitPlaybackState(bass.BassProcessingState.buffering);
      await _waitUntil(() => harness.audio.pauseCount == 1);
      harness.audio.pauseGate = null;
      await harness.controller.pauseForSleepTimer();
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(harness.audio.playCount, 1);
      expect(harness.audio.playing, isFalse);
    },
  );

  test('brief buffering resumes without watchdog interference', () async {
    final harness = await _Harness.create(
      loadFailures: 0,
      stallRecoveryDelay: const Duration(milliseconds: 40),
    );
    addTearDown(harness.dispose);

    await harness.controller.playFromMusic(_music());
    final logStart = AppLogger.recentMemoryLines.length;
    final playCount = harness.audio.playCount;
    harness.audio.emitPlaybackState(bass.BassProcessingState.buffering);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    harness.audio.emitPlaybackState(bass.BassProcessingState.ready);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(harness.audio.pauseCount, 0);
    expect(harness.audio.playCount, playCount);
    expect(
      harness.container.read(playerControllerProvider).processingState,
      PlayerProcessingState.ready,
    );
    final logs = AppLogger.recentMemoryLines.skip(logStart).join('\n');
    expect(logs, contains('[player-playback] buffering_start'));
    expect(logs, contains('[player-playback] buffering_end'));
    expect(logs, isNot(contains('https://audio.test')));
  });

  test(
    'prolonged buffering restarts once then resumes from a fallback',
    () async {
      final harness = await _Harness.create(
        loadFailures: 0,
        stallRecoveryDelay: const Duration(milliseconds: 10),
      );
      addTearDown(harness.dispose);

      await harness.controller.playFromMusic(_music());
      await harness.controller.seek(const Duration(seconds: 42));
      final playCount = harness.audio.playCount;

      harness.audio.emitPlaybackState(bass.BassProcessingState.buffering);
      await _waitUntil(
        () =>
            harness.audio.pauseCount == 1 &&
            harness.audio.playCount == playCount + 1,
      );

      harness.audio.emitPlaybackState(bass.BassProcessingState.buffering);
      await _waitUntil(
        () =>
            harness.audio.loadedUris.length == 2 &&
            harness.container.read(playerControllerProvider).track?.remoteUrl ==
                'https://audio.test/second.mp3',
      );

      expect(
        harness.audio.loadedUris.last,
        Uri.parse('https://audio.test/second.mp3'),
      );
      expect(harness.audio.seekPositions.last, const Duration(seconds: 42));
      expect(harness.container.read(playerControllerProvider).error, isNull);
    },
  );

  test('quality switch keeps position, lyrics, and paused state', () async {
    final harness = await _Harness.create(loadFailures: 0);
    addTearDown(harness.dispose);

    await harness.controller.playFromMusic(_music());
    await _waitUntil(
      () => harness.container.read(playerControllerProvider).lyricInfo != null,
    );
    await harness.controller.seek(const Duration(seconds: 42));
    final before = harness.container.read(playerControllerProvider);
    final lyricsBefore = before.lyrics;
    final lyricLoadsBefore = harness.api.lyricLoadCount;

    expect(before.playing, isFalse);
    expect(before.track?.availableQualities, contains(Quality.k320));
    expect(await harness.controller.switchQuality(Quality.k320), isTrue);

    final after = harness.container.read(playerControllerProvider);
    expect(after.track?.qualityLabel, Quality.k320.code);
    expect(after.position, const Duration(seconds: 42));
    expect(identical(after.lyrics, lyricsBefore), isTrue);
    expect(after.playing, isFalse);
    expect(harness.api.lyricLoadCount, lyricLoadsBefore);
    expect(harness.resolver.requestedQualities, [Quality.k128, Quality.k320]);
  });

  test(
    'quality switch succeeds even if restore seek fails with error 7',
    () async {
      final harness = await _Harness.create(loadFailures: 0);
      addTearDown(harness.dispose);

      await harness.controller.playFromMusic(_music());
      await _waitUntil(
        () =>
            harness.container.read(playerControllerProvider).lyricInfo != null,
      );
      await harness.controller.seek(const Duration(seconds: 42));
      expect(
        harness.container
            .read(playerControllerProvider)
            .track
            ?.availableQualities,
        contains(Quality.k320),
      );

      // Simulate seek error 7 on next seek (restore seek)
      harness.audio.failNextSeek = true;

      expect(await harness.controller.switchQuality(Quality.k320), isTrue);

      final after = harness.container.read(playerControllerProvider);
      expect(after.track?.qualityLabel, Quality.k320.code);
      expect(harness.resolver.requestedQualities, [Quality.k128, Quality.k320]);
    },
  );

  test('failed quality switch keeps the previous quality retryable', () async {
    final harness = await _Harness.create(loadFailures: 0);
    addTearDown(harness.dispose);

    await harness.controller.playFromMusic(_music());
    harness.resolver.failingQualities.add(Quality.k320);

    expect(await harness.controller.switchQuality(Quality.k320), isFalse);
    expect(
      harness.container.read(playerControllerProvider).track?.qualityLabel,
      Quality.k128.code,
    );

    expect(await harness.controller.switchQuality(Quality.k320), isFalse);
    expect(harness.resolver.requestedQualities, [
      Quality.k128,
      Quality.k320,
      Quality.k320,
    ]);
  });

  group('automatic crossfade', () {
    test('a prepared 6 ms fade starts between position events', () async {
      final harness = await _startCrossfadeQueue(seconds: 0);
      final settings = harness.container.read(settingsProvider.notifier);
      await settings.setCrossfadeMilliseconds(6);
      // Prepare well ahead, then deliver the last UI tick before the cue.
      harness.audio.emitPosition(const Duration(seconds: 179));
      await _waitUntil(() => harness.audio.preparedUris.isNotEmpty);
      await Future<void>.delayed(Duration.zero);
      harness.audio.emitPosition(const Duration(milliseconds: 179970));
      expect(harness.audio.startedFades, isEmpty);
      // The native clock advances without broadcasting another position event.
      harness.audio._position = const Duration(milliseconds: 179994);
      await _waitUntil(() => harness.audio.startedFades.isNotEmpty);
      expect(harness.audio.startedFades.single, const Duration(milliseconds: 6));
    });

    test('disabling a prepared short fade cancels its pending cue', () async {
      final harness = await _startCrossfadeQueue(seconds: 0);
      final settings = harness.container.read(settingsProvider.notifier);
      await settings.setCrossfadeMilliseconds(6);
      harness.audio.emitPosition(const Duration(seconds: 179));
      await _waitUntil(() => harness.audio.preparedUris.isNotEmpty);
      await Future<void>.delayed(Duration.zero);
      harness.audio.emitPosition(const Duration(milliseconds: 179970));
      await settings.setCrossfadeMilliseconds(0);
      harness.audio._position = const Duration(milliseconds: 179994);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(harness.audio.startedFades, isEmpty);
      expect(
        harness.audio.cancelledFades,
        contains(harness.audio.preparedTokens.single),
      );
    });

    test(
      'zero seconds keeps natural completion as the only transition',
      () async {
        final harness = await _startCrossfadeQueue(seconds: 0);
        harness.audio.emitPosition(const Duration(seconds: 179));
        await Future<void>.delayed(Duration.zero);

        expect(harness.audio.preparedUris, isEmpty);
        expect(harness.audio.startedFades, isEmpty);
        expect(harness.audio.currentMediaItem?.title, 'first');
        harness.audio.emitPlaybackState(bass.BassProcessingState.completed);
        await _waitUntil(
          () => harness.audio.currentMediaItem?.title == 'second',
        );
        expect(harness.audio.loadedUris, hasLength(2));
      },
    );

    test(
      'overlaps two tracks and publishes the incoming queue position',
      () async {
        final harness = await _startCrossfadeQueue(seconds: 4);
        final gate = harness.audio.prepareGate = Completer<bool>();
        harness.audio.emitPosition(const Duration(seconds: 174));
        await _waitUntil(() => harness.audio.preparedUris.isNotEmpty);

        expect(
          harness.audio.preparedUris.single.pathSegments.last,
          'second.mp3',
        );
        expect(harness.audio.currentMediaItem?.title, 'first');
        expect(harness.container.read(playerControllerProvider).queueIndex, 0);
        gate.complete(true);
        await Future<void>.delayed(Duration.zero);
        expect(harness.audio.startedFades, isEmpty);
        harness.audio.emitPosition(const Duration(seconds: 176));
        await _waitUntil(
          () => harness.audio.currentMediaItem?.title == 'second',
        );

        final state = harness.container.read(playerControllerProvider);
        expect(harness.audio.startedFades, [const Duration(seconds: 4)]);
        expect(harness.audio.loadedUris, hasLength(1));
        expect(state.track?.title, 'second');
        expect(state.queue[state.queueIndex].id, 'second');
        expect(state.position, Duration.zero);
        expect(state.playing, isTrue);
        expect(harness.audio.playbackState.value.queueIndex, 1);
      },
    );

    test(
      'remote crossfade tries the next source and recovers an immediate stall',
      () async {
        SharedPreferences.setMockInitialValues({'crossfade_seconds': 4});
        final harness = await _Harness.create(
          loadFailures: 0,
          stallRecoveryDelay: const Duration(milliseconds: 20),
        );
        addTearDown(harness.dispose);
        final entries = [
          for (final id in ['A', 'B'])
            DownloadHistoryEntry.fromJson({
              'id': id,
              'musicId': id,
              'name': 'Song $id',
              'source': 'kw',
              'quality': '128k',
              'musicInfo': {
                'id': id,
                'name': 'Song $id',
                'singer': 'Singer $id',
                'source': 'kw',
                'interval': '03:00',
                'meta': {
                  'songId': id,
                  'albumName': 'Album $id',
                  'qualitys': [{'type': '128k'}],
                },
              },
            }),
        ];
        await harness.controller.playFromPlaylistQueue(entries.first, entries);
        harness.audio.emitPlaybackState(bass.BassProcessingState.ready);
        final firstSource = Uri.parse('https://audio.test/first.mp3');
        final secondSource = Uri.parse('https://audio.test/second.mp3');
        harness.audio.failedPreparations.add(firstSource);
        harness.audio.startState = bass.BassProcessingState.buffering;
        final playCount = harness.audio.playCount;
        final pauseCount = harness.audio.pauseCount;
        harness.audio.emitPosition(const Duration(seconds: 176));

        await _waitUntil(() {
          final incoming = harness.container.read(playerControllerProvider);
          return incoming.track?.title == 'Song B' &&
              !incoming.lyricLoading && incoming.lyricInfo != null;
        });
        final state = harness.container.read(playerControllerProvider);
        expect(harness.audio.preparedUris, [firstSource, secondSource]);
        expect(harness.audio.startedFades, [const Duration(seconds: 4)]);
        expect(harness.audio.loadedUris, [firstSource]);
        expect(state.track?.remoteUrl, secondSource.toString());
        expect(state.queue[state.queueIndex].id, 'B');
        expect(harness.audio.playbackState.value.queueIndex, 1);
        expect(harness.audio.currentMediaItem?.artist, 'Singer B');
        expect(harness.audio.currentMediaItem?.album, 'Album B');
        expect(state.lyrics.lines.single.text, 'Song B lyric');
        expect(state.error, isNull);

        // The native handoff emits buffering once. No later state tick arms
        // the watchdog on its behalf.
        await _waitUntil(() => harness.audio.playCount == playCount + 1);
        expect(harness.audio.pauseCount, pauseCount + 1);
        expect(harness.audio.loadedUris, [firstSource]);
      },
    );

    test('standalone playback overlaps its sole enqueued successor', () async {
      final harness = await _startCrossfadeQueue(seconds: 4);
      final next = harness.container.read(playerControllerProvider).queue.last;
      await harness.controller.playFromMusic(_music());
      await harness.controller.enqueueNext(next);
      harness.audio.emitPlaybackState(bass.BassProcessingState.ready);
      final before = harness.container.read(playerControllerProvider);
      expect(before.queue, hasLength(1));
      expect(before.queueIndex, -1);
      final loads = harness.audio.loadedUris.length;

      harness.audio.emitPosition(const Duration(seconds: 176));
      await _waitUntil(
        () => harness.audio.currentMediaItem?.title == next.name,
      );
      expect(harness.audio.startedFades, [const Duration(seconds: 4)]);
      expect(harness.audio.loadedUris, hasLength(loads));
      expect(harness.container.read(playerControllerProvider).queueIndex, 0);
    });

    test(
      'a declined start reflects system pause and can retry on resume',
      () async {
        final harness = await _startCrossfadeQueue(seconds: 4);
        final gate = harness.audio.startGate = Completer<bool>();
        harness.audio.emitPosition(const Duration(seconds: 176));
        await _waitUntil(() => harness.audio.startedFades.isNotEmpty);
        await harness.audio.pause();
        harness.audio.emitPlaybackState(bass.BassProcessingState.ready);
        gate.complete(false);
        await Future<void>.delayed(Duration.zero);

        final paused = harness.container.read(playerControllerProvider);
        expect(paused.playing, isFalse);
        expect(paused.track?.title, 'first');
        expect(paused.queueIndex, 0);
        harness.audio.startGate = null;
        await harness.audio.play();
        harness.audio.emitPlaybackState(bass.BassProcessingState.ready);
        harness.audio.emitPosition(const Duration(seconds: 177));
        await _waitUntil(
          () => harness.audio.currentMediaItem?.title == 'second',
        );
        expect(harness.audio.startedFades.last, const Duration(seconds: 3));
      },
    );

    test(
      'failed preparation leaves the current track until completion',
      () async {
        final harness = await _startCrossfadeQueue(seconds: 4);
        harness.audio.prepareGate = Completer<bool>()..complete(false);
        harness.audio.emitPosition(const Duration(seconds: 176));
        await _waitUntil(() => harness.audio.preparedUris.isNotEmpty);
        await Future<void>.delayed(Duration.zero);
        expect(harness.audio.startedFades, isEmpty);
        expect(harness.audio.currentMediaItem?.title, 'first');
        expect(harness.container.read(playerControllerProvider).error, isNull);

        harness.audio.emitPlaybackState(bass.BassProcessingState.completed);
        await _waitUntil(
          () => harness.audio.currentMediaItem?.title == 'second',
        );
        expect(harness.audio.loadedUris, hasLength(2));
        expect(harness.container.read(playerControllerProvider).queueIndex, 1);
      },
    );

    for (final changeTrack in [false, true]) {
      final action = changeTrack ? 'manual track change' : 'seek';
      test('a $action cancels a pending decoder', () async {
        final harness = await _startCrossfadeQueue(seconds: 4);
        final gate = harness.audio.prepareGate = Completer<bool>();
        harness.audio.emitPosition(const Duration(seconds: 176));
        await _waitUntil(() => harness.audio.preparedUris.isNotEmpty);
        if (changeTrack) {
          await harness.controller.playQueueItem(2);
        } else {
          await harness.controller.seek(const Duration(seconds: 10));
        }
        gate.complete(true);
        await Future<void>.delayed(Duration.zero);

        expect(
          harness.audio.cancelledFades,
          contains(harness.audio.preparedTokens.single),
        );
        expect(harness.audio.startedFades, isEmpty);
        expect(
          harness.audio.currentMediaItem?.title,
          changeTrack ? 'third' : 'first',
        );
        expect(
          harness.container.read(playerControllerProvider).queueIndex,
          changeTrack ? 2 : 0,
        );
      });
    }
  });

  test('enqueue next stays next when shuffle mode is active', () async {
    final harness = await _Harness.create(loadFailures: 0);
    addTearDown(harness.dispose);
    final directory = await Directory.systemTemp.createTemp(
      'cyshine-player-shuffle-next-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final entries = <DownloadHistoryEntry>[];
    for (final id in ['current', 'other-a', 'other-b', 'forced-next']) {
      final file = File('${directory.path}${Platform.pathSeparator}$id.mp3');
      await file.writeAsBytes(const [0]);
      entries.add(_localEntry(id, file.path));
    }

    await harness.controller.playFromHistoryQueue(entries.first, entries);
    harness.controller.setPlaybackMode(PlayerPlaybackMode.shuffle);
    await harness.controller.enqueueNext(entries.last);
    await harness.controller.playNext();

    final state = harness.container.read(playerControllerProvider);
    expect(state.track?.localPath, entries.last.savedPath);
    expect(state.queue[state.queueIndex].id, 'forced-next');
  });

  test(
    'shuffle next enters an enqueued queue after standalone playback',
    () async {
      final harness = await _Harness.create(loadFailures: 0);
      addTearDown(harness.dispose);
      final directory = await Directory.systemTemp.createTemp(
        'cyshine-player-standalone-next-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        '${directory.path}${Platform.pathSeparator}forced-next.mp3',
      );
      await file.writeAsBytes(const [0]);
      final next = _localEntry('forced-next', file.path);

      await harness.controller.playFromMusic(_music());
      harness.controller.setPlaybackMode(PlayerPlaybackMode.shuffle);
      await harness.controller.enqueueNext(next);
      await harness.controller.playNext();

      final state = harness.container.read(playerControllerProvider);
      expect(state.track?.localPath, next.savedPath);
      expect(state.queueIndex, 0);
    },
  );

  test(
    'playlist keeps both occurrences of the same downloaded Spotify track',
    () async {
      final harness = await _Harness.create(loadFailures: 0);
      addTearDown(harness.dispose);
      final directory = await Directory.systemTemp.createTemp(
        'cyshine-repeat-track-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File('${directory.path}/same.mp3').writeAsBytes([0]);
      final original = _localEntry('same', file.path).toJson();
      final entries = [
        DownloadHistoryEntry.fromJson(original),
        for (var position = 0; position < 2; position++)
          DownloadHistoryEntry.fromJson({
            ...original,
            'id': 'row-$position',
            'preservePlaylistPosition': true,
          }),
      ];
      await harness.controller.playFromPlaylistQueue(entries.last, entries);
      final state = harness.container.read(playerControllerProvider);
      expect(state.queue.map((entry) => entry.id), ['same', 'row-0', 'row-1']);
      expect(state.queueIndex, 2);
    },
  );

  test('playlist queue expands without restarting the active track', () async {
    final harness = await _Harness.create(loadFailures: 0);
    addTearDown(harness.dispose);
    final directory = await Directory.systemTemp.createTemp(
      'cyshine-player-expand-queue-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final expanded = <DownloadHistoryEntry>[];
    for (var index = 1; index <= 5; index++) {
      final file = File(
        '${directory.path}${Platform.pathSeparator}track-$index.mp3',
      );
      await file.writeAsBytes(const [0]);
      expanded.add(_localEntry('track-$index', file.path));
    }
    final initial = expanded.take(3).toList(growable: false);

    await harness.controller.playFromPlaylistQueue(initial[1], initial);
    final before = harness.container.read(playerControllerProvider);
    final loadedBefore = harness.audio.loadedUris.length;

    expect(
      harness.controller.expandPlaylistQueue(
        expectedQueue: initial,
        expandedQueue: expanded,
      ),
      isTrue,
    );

    final after = harness.container.read(playerControllerProvider);
    expect(after.queue, hasLength(5));
    expect(after.queueIndex, 1);
    expect(after.queue[after.queueIndex].id, 'track-2');
    expect(after.track?.id, before.track?.id);
    expect(harness.audio.loadedUris, hasLength(loadedBefore));
  });
}

Future<_Harness> _startCrossfadeQueue({required int seconds}) async {
  SharedPreferences.setMockInitialValues({'crossfade_seconds': seconds});
  final directory = await Directory.systemTemp.createTemp(
    'cyshine-player-crossfade-',
  );
  addTearDown(() => directory.delete(recursive: true));
  final entries = <DownloadHistoryEntry>[];
  for (final id in ['first', 'second', 'third']) {
    final file = await File.fromUri(directory.uri.resolve('$id.mp3'))
        .writeAsBytes([0]);
    entries.add(_localEntry(id, file.path));
  }
  final harness = await _Harness.create(loadFailures: 0);
  addTearDown(harness.dispose);
  await harness.controller.playFromPlaylistQueue(entries.first, entries);
  harness.audio.emitPlaybackState(bass.BassProcessingState.ready);
  return harness;
}

class _Harness {
  _Harness({
    required this.container,
    required this.audio,
    required this.resolver,
    required this.api,
  });

  final ProviderContainer container;
  final _FakeAudioHandler audio;
  final _ScriptedResolver resolver;
  final _FakeMusicApi api;

  PlayerController get controller =>
      container.read(playerControllerProvider.notifier);

  static Future<_Harness> create({
    required int loadFailures,
    Duration stallRecoveryDelay = const Duration(seconds: 12),
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final audio = _FakeAudioHandler(loadFailures: loadFailures);
    final resolver = _ScriptedResolver([_record('first'), _record('second')]);
    final api = _FakeMusicApi();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        playerAudioHandlerProvider.overrideWithValue(audio),
        musicUrlResolverProvider.overrideWithValue(resolver),
        musicApiProvider.overrideWithValue(api),
        playbackStallRecoveryDelayProvider.overrideWithValue(
          stallRecoveryDelay,
        ),
      ],
    );
    container.read(playerControllerProvider);
    return _Harness(
      container: container,
      audio: audio,
      resolver: resolver,
      api: api,
    );
  }

  Future<void> dispose() async {
    container.dispose();
    await audio.disposeHandler();
  }
}

class _ScriptedResolver implements MusicUrlResolver {
  _ScriptedResolver(this.sources);

  final List<MusicSourceRecord> sources;
  final List<String> attemptedIds = [];
  final List<Quality> requestedQualities = [];
  final Set<Quality> failingQualities = {};

  @override
  Future<Quality> highestQualityFor(MusicInfo music) async => Quality.k128;

  @override
  Future<MusicUrl> resolve({
    required MusicInfo music,
    required Quality quality,
  }) async {
    final result = await useFirstAvailable<MusicUrl>(
      music: music,
      quality: quality,
      use: (_, url) async => url,
    );
    return result.value;
  }

  @override
  Future<MusicSourceFallbackResult<T>> useFirstAvailable<T>({
    required MusicInfo music,
    required Quality quality,
    required MusicSourceUrlConsumer<T> use,
    Set<String> excludedSourceIds = const <String>{},
    bool Function()? isCancelled,
    bool Function(Object error)? shouldFallbackOnConsumerError,
  }) async {
    requestedQualities.add(quality);
    final failures = <MusicSourceAttemptFailure>[];
    final attempted = <String>[];
    for (final source in sources) {
      if (excludedSourceIds.contains(source.id)) continue;
      if (isCancelled?.call() ?? false) {
        throw const MusicSourceFallbackCancelledException();
      }
      attempted.add(source.id);
      attemptedIds.add(source.id);
      try {
        if (failingQualities.contains(quality)) {
          throw const MusicSourceRuntimeException('quality unavailable');
        }
        final url = MusicUrl(
          url: 'https://audio.test/${source.id}.mp3',
          type: quality,
        );
        final value = await use(source, url);
        return MusicSourceFallbackResult(
          source: source,
          value: value,
          attemptedSourceIds: List.unmodifiable(attempted),
        );
      } on MusicSourceFallbackCancelledException {
        rethrow;
      } catch (error) {
        failures.add(MusicSourceAttemptFailure(source: source, error: error));
      }
    }
    if (failures.isEmpty) {
      throw const MusicSourceRuntimeException('没有更多可用的备用音源');
    }
    throw MusicSourceFallbackException(failures);
  }
}

class _FakeAudioHandler extends PlayerAudioHandler {
  _FakeAudioHandler({required this.loadFailures});

  final int loadFailures;
  final List<Uri> loadedUris = [];
  final List<Uri> preparedUris = [];
  final Set<Uri> failedPreparations = {};
  var startState = bass.BassProcessingState.ready;
  final List<int> preparedTokens = [];
  final List<int> cancelledFades = [];
  final List<Duration> startedFades = [];
  Completer<bool>? prepareGate;
  Completer<bool>? startGate;
  final _positions = StreamController<Duration>.broadcast(sync: true);
  final StreamController<bass.BassPlayerException> _errors =
      StreamController<bass.BassPlayerException>.broadcast(sync: true);
  final StreamController<bass.BassPlaybackSnapshot> _states =
      StreamController<bass.BassPlaybackSnapshot>.broadcast(sync: true);
  int failTransitionCount = 0;
  int playCount = 0;
  int pauseCount = 0;
  Completer<void>? loadGate;
  Completer<void>? pauseGate;
  bool failNextSeek = false;
  final List<Duration> seekPositions = [];
  Duration? _duration;
  Duration _position = Duration.zero;
  bool _playing = false;
  bass.BassProcessingState _processingState = bass.BassProcessingState.idle;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  void emitPosition(Duration position) {
    _position = position;
    _positions.add(position);
  }

  @override
  Future<bool> prepareCrossfade(
    Uri source, {
    required int token,
    String? formatHint,
  }) async {
    preparedUris.add(source);
    preparedTokens.add(token);
    if (failedPreparations.contains(source)) return false;
    return await prepareGate?.future ?? true;
  }

  @override
  Future<bool> startCrossfade({
    required int token,
    required Duration duration,
  }) async {
    expect(token, preparedTokens.last);
    startedFades.add(duration);
    if (!(await startGate?.future ?? true)) return false;
    emitPosition(Duration.zero);
    emitPlaybackState(startState);
    return true;
  }

  @override
  Future<void> cancelCrossfade(int token) async => cancelledFades.add(token);

  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();

  @override
  Stream<bass.BassPlaybackSnapshot> get playerStateStream => _states.stream;

  @override
  Stream<bass.BassPlayerException> get errorStream => _errors.stream;

  @override
  Duration get position => _position;

  @override
  Duration? get duration => _duration;

  @override
  bool get playing => _playing;

  @override
  bass.BassProcessingState get processingState => _processingState;

  @override
  void publishQueue(List<MediaItem> items, {int? currentIndex}) {
    // Queue updates must preserve the fake transport's actual state, not
    // rebroadcast the BaseAudioHandler's initial idle state after load().
    queue.add(items);
    playbackState.add(playbackState.value.copyWith(
      queueIndex: currentIndex,
      playing: _playing,
      processingState: switch (_processingState) {
        bass.BassProcessingState.idle => AudioProcessingState.idle,
        bass.BassProcessingState.loading => AudioProcessingState.loading,
        bass.BassProcessingState.buffering => AudioProcessingState.buffering,
        bass.BassProcessingState.ready => AudioProcessingState.ready,
        bass.BassProcessingState.completed => AudioProcessingState.completed,
        bass.BassProcessingState.error => AudioProcessingState.error,
      },
    ));
  }

  @override
  Future<void> beginTrackTransition({
    required MediaItem item,
    int? queueIndex,
  }) async {
    _playing = false;
    _processingState = bass.BassProcessingState.loading;
  }

  @override
  Future<Duration?> load({
    required MediaItem item,
    required Uri sourceUri,
    int? queueIndex,
  }) async {
    loadedUris.add(sourceUri);
    await loadGate?.future;
    if (loadedUris.length <= loadFailures) {
      throw const bass.BassPlayerException(code: 1, message: 'load failed');
    }
    _position = Duration.zero;
    _duration = const Duration(minutes: 3);
    updateMediaMetadata(item);
    _processingState = bass.BassProcessingState.ready;
    return _duration;
  }

  @override
  Future<void> play() async {
    playCount++;
    _playing = true;
    _processingState = bass.BassProcessingState.ready;
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    await pauseGate?.future;
    _playing = false;
    _processingState = bass.BassProcessingState.ready;
  }

  @override
  Future<void> seek(Duration position) async {
    if (failNextSeek) {
      failNextSeek = false;
      throw const bass.BassPlayerException(
        code: 7,
        message: 'position is not seekable',
      );
    }
    _position = position;
    seekPositions.add(position);
  }

  @override
  void failTrackTransition(Object error) {
    failTransitionCount++;
  }

  void emitError(bass.BassPlayerException error) => _errors.add(error);

  void emitPlaybackState(bass.BassProcessingState processingState) {
    _processingState = processingState;
    _states.add(
      bass.BassPlaybackSnapshot(
        playing: _playing,
        processingState: processingState,
        position: _position,
        bufferedPosition: _position,
        duration: _duration,
      ),
    );
  }

  @override
  Future<void> disposeHandler() async {
    await _positions.close();
    await _errors.close();
    await _states.close();
    await super.disposeHandler();
  }
}

class _FakeMusicApi extends MusicApi {
  int lyricLoadCount = 0;
  String? coverUrl;

  @override
  Future<LyricInfo> getLyric({required MusicInfo musicInfo}) async {
    lyricLoadCount++;
    return LyricInfo(lyric: '[00:01.000]${musicInfo.name} lyric');
  }

  @override
  Future<String?> getPicUrl({
    required MusicInfo musicInfo,
    bool preferCached = true,
  }) async => coverUrl;
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final widgetLogs = AppLogger.recentMemoryLines
      .where((line) => line.contains('[widget-sync]'))
      .join('\n');
  fail('condition was not reached; Widget diagnostics:\n$widgetLogs');
}

MusicSourceRecord _record(String id) {
  return MusicSourceRecord(
    id: id,
    name: id,
    description: '',
    author: 'test',
    homepage: '',
    version: '1',
    origin: 'test',
    importedAt: DateTime.utc(2026, 7, 31),
    updatedAt: DateTime.utc(2026, 7, 31),
    capabilities: const {
      MusicSource.kw: [Quality.k320, Quality.k128],
    },
  );
}

MusicInfo _music() {
  return MusicInfo(
    id: 'song-1',
    name: 'Test Song',
    singer: 'Test Singer',
    source: MusicSource.kw,
    interval: '03:00',
    meta: const MusicMeta(
      songId: 'song-1',
      albumName: 'Test Album',
      qualitys: [QualityOption(type: Quality.k128)],
      raw: {},
    ),
    raw: const {},
  );
}

MusicInfo _neteaseMusic() {
  return MusicInfo(
    id: 'netease-song',
    name: 'NetEase Song',
    singer: 'Test Singer',
    source: MusicSource.wy,
    interval: '03:00',
    meta: const MusicMeta(
      songId: 'netease-song',
      albumName: 'Test Album',
      picUrl: 'http://p1.music.126.net/test/cover.jpg',
      qualitys: [QualityOption(type: Quality.k128)],
      raw: {},
    ),
    raw: const {},
  );
}

DownloadHistoryEntry _localEntry(String id, String path) {
  return DownloadHistoryEntry(
    id: id,
    musicId: id,
    name: id,
    singer: 'Test Singer',
    albumName: 'Test Album',
    sourceCode: MusicSource.kw.code,
    qualityCode: Quality.k128.code,
    status: DownloadHistoryStatus.completed,
    createdAt: DateTime.utc(2026, 8, 4),
    savedPath: path,
  );
}
