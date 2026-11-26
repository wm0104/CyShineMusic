import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/downloads/download_progress.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/services/download_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  ProviderContainer open() => ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
  ]);

  test(
    'batch downloads are deduplicated, isolated, and capped at three',
    () async {
      late _RecordingDownloadService service;
      final serviceProvider = Provider<_RecordingDownloadService>(
        (ref) => service = _RecordingDownloadService(ref, failIds: {'song-4'}),
      );
      final container = open();
      addTearDown(container.dispose);
      container.read(serviceProvider);

      final musics = [
        for (var index = 0; index < 8; index++) _music('song-$index'),
        _music('song-2'),
      ];
      final results = await service.downloadMany(
        musics: musics,
        concurrency: 99,
      );

      expect(results, hasLength(8));
      expect(service.calls, hasLength(8));
      expect(service.qualities, everyElement(isNull));
      expect(service.maxActive, 3);
      expect(results.where((item) => item.success), hasLength(7));
      expect(results.singleWhere((item) => !item.success).music.id, 'song-4');
      final tasks = container.read(downloadProgressProvider).tasks;
      expect(tasks, hasLength(8));
      expect(tasks.where((task) => task.stage == DownloadStage.done), hasLength(7));
      expect(tasks.singleWhere((task) => task.stage == DownloadStage.failed).musicId, 'song-4');
      expect(tasks.any((task) => task.isBusy), isFalse);
    },
  );

  test(
    'a running batch reserves its songs against duplicate submission',
    () async {
      final blocker = Completer<void>();
      late _RecordingDownloadService service;
      final serviceProvider = Provider<_RecordingDownloadService>(
        (ref) => service = _RecordingDownloadService(ref, blocker: blocker),
      );
      final container = open();
      addTearDown(container.dispose);
      container.read(serviceProvider);

      final music = _music('same-song');
      final first = service.downloadMany(musics: [music]);
      await service.firstStarted.future;

      final duplicate = await service.downloadMany(musics: [music]);
      expect(duplicate, isEmpty);
      expect(service.calls, ['same-song']);
      expect(container.read(downloadProgressProvider).tasks, hasLength(1));
      final taskId = container.read(downloadProgressProvider).tasks.single.id;

      blocker.complete();
      expect((await first).single.success, isTrue);
      expect(container.read(downloadProgressProvider).tasks.single.id, taskId);
      expect(container.read(downloadProgressProvider).tasks.single.stage, DownloadStage.done);
    },
  );

  test('batch downloads apply the selected quality preference', () async {
    late _RecordingDownloadService service;
    final serviceProvider = Provider<_RecordingDownloadService>(
      (ref) => service = _RecordingDownloadService(ref),
    );
    final container = open();
    addTearDown(container.dispose);
    container.read(serviceProvider);

    await service.downloadMany(
      musics: [
        _musicWithQualities('lossless-song', [
          Quality.flac,
          Quality.k320,
          Quality.k128,
        ]),
      ],
      qualityPreference: OnlinePlaybackQuality.high,
    );

    expect(service.qualities, [Quality.k320]);
    expect(container.read(downloadProgressProvider).tasks.single.qualityCode, Quality.k320.code);
    expect(container.read(downloadProgressProvider).tasks.single.stage, DownloadStage.done);
  });
}

class _RecordingDownloadService extends DownloadService {
  _RecordingDownloadService(this.testRef, {this.failIds = const {}, this.blocker})
      : super(testRef);

  final Ref testRef;
  final Set<String> failIds;
  final Completer<void>? blocker;
  final Completer<void> firstStarted = Completer<void>();
  final List<String> calls = [];
  final List<Quality?> qualities = [];
  int active = 0;
  int maxActive = 0;

  @override
  Future<DownloadResult> downloadOne({
    required MusicInfo music,
    Quality? quality,
    required EmbedRequest embed,
  }) async {
    final task = testRef.read(downloadProgressProvider).tasks.singleWhere(
      (task) => task.musicId == music.id && task.stage == DownloadStage.queued,
    );
    final progress = testRef.read(downloadProgressProvider.notifier);
    progress.updateStage(task.id, DownloadStage.downloading);
    calls.add(music.id);
    qualities.add(quality);
    active += 1;
    if (active > maxActive) maxActive = active;
    if (!firstStarted.isCompleted) firstStarted.complete();
    try {
      if (blocker != null) {
        await blocker!.future;
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 8));
      }
      if (failIds.contains(music.id)) throw StateError('download failed');
      final path = 'D:/Music/${music.id}.mp3';
      progress.finish(task.id, path);
      return DownloadResult(path: path);
    } catch (error) {
      progress.fail(task.id, error.toString());
      rethrow;
    } finally {
      active -= 1;
    }
  }
}

MusicInfo _music(String id) {
  return _musicWithQualities(id, [Quality.k320]);
}

MusicInfo _musicWithQualities(String id, List<Quality> qualities) {
  return MusicInfo.fromJson({
    'id': id,
    'name': '歌曲 $id',
    'singer': '歌手',
    'source': MusicSource.wy.code,
    'interval': '03:30',
    'meta': {
      'songId': id,
      'albumName': '专辑',
      'qualitys': [
        for (final quality in qualities) {'type': quality.code, 'size': '1024'},
      ],
    },
  });
}
