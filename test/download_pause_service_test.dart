import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cy_shine_music/core/api/api_client.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/lyric_format.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/models/music_url.dart';
import 'package:cy_shine_music/core/music_sources/music_source_models.dart';
import 'package:cy_shine_music/core/music_sources/music_url_resolver.dart';
import 'package:cy_shine_music/core/services/download_service.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/downloads/download_progress.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ProviderContainer container;
  late _Adapter adapter;
  late DownloadService service;
  late List<String> pathCalls;
  setUp(() async {
    pathCalls = [];
    root = await Directory.systemTemp.createTemp('cyshine-pause-');
    final musicDir = await Directory('${root.path}/music').create();
    final cacheDir = await Directory('${root.path}/cache').create();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        pathCalls.add(call.method);
        return call.method == 'getTemporaryDirectory' ? cacheDir.path : null;
      },
    );
    SharedPreferences.setMockInitialValues({'download_dir': musicDir.path});
    final prefs = await SharedPreferences.getInstance();
    adapter = _Adapter();
    final dio = Dio()..httpClientAdapter = adapter;
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      apiClientProvider.overrideWithValue(dio),
      musicUrlResolverProvider.overrideWithValue(_Resolver()),
    ]);
    service = container.read(downloadServiceProvider);
  });
  tearDown(() async {
    container.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'), null,
    );
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('pause cancels the actual Dio transfer; continue completes the same task and valid done never redownloads', () async {
    final first = service.downloadOne(music: _music, quality: Quality.k128, embed: _embed);
    final stopped = expectLater(first, throwsA(isA<DownloadPausedException>()));
    await adapter.started.future;
    final id = container.read(downloadProgressProvider).tasks.single.id;
    service.pauseTask(id);
    expect(container.read(downloadProgressProvider).tasks.single.stage, DownloadStage.paused);
    await stopped;
    expect(adapter.wasCancelled, isTrue);
    adapter.hold = false;
    await service.resumeTask(id);
    final task = container.read(downloadProgressProvider).tasks.single;
    expect(task.id, id);
    expect(task.stage, DownloadStage.done);
    expect(File(task.savedPath!).existsSync(), isTrue);
    final calls = adapter.calls;
    final result = await service.downloadOne(music: _music, quality: Quality.k128, embed: _embed);
    expect(result.path, task.savedPath);
    expect(adapter.calls, calls);
  });

  test('rebuilding the progress provider cancels old work and never starts restored tasks automatically', () async {
    final first = service.downloadOne(music: _music, quality: Quality.k128, embed: _embed);
    final stopped = expectLater(first, throwsA(isA<DownloadPausedException>()));
    await adapter.started.future;
    await container.read(downloadProgressProvider.notifier).flushPersistence();
    container.invalidate(downloadProgressProvider);
    final restored = container.read(downloadProgressProvider).tasks.single;
    expect(restored.stage, DownloadStage.paused);
    await stopped;
    final calls = adapter.calls;
    await Future<void>.delayed(Duration.zero);
    expect(adapter.calls, calls);
    adapter.hold = false;
    await service.resumeTask(restored.id);
    expect(container.read(downloadProgressProvider).tasks.single.stage, DownloadStage.done);
  });

  test('rebuilding only the service leaves orphaned work paused until explicitly continued', () async {
    final first = service.downloadOne(music: _music, quality: Quality.k128, embed: _embed);
    final stopped = expectLater(first, throwsA(isA<DownloadPausedException>()));
    await adapter.started.future;
    container.invalidate(downloadServiceProvider);
    service = container.read(downloadServiceProvider);
    await stopped;
    await Future<void>.delayed(Duration.zero);
    final restored = container.read(downloadProgressProvider).tasks.single;
    expect(restored.stage, DownloadStage.paused);
    final calls = adapter.calls;
    await Future<void>.delayed(Duration.zero);
    expect(adapter.calls, calls);
    adapter.hold = false;
    await service.resumeTask(restored.id);
    expect(container.read(downloadProgressProvider).tasks.single.stage, DownloadStage.done);
  });

  test('pause all also persists not-yet-started batch jobs and continue all completes them', () async {
    final batch = service.downloadMany(musics: [
      for (var index = 0; index < 5; index++) MusicInfo.fromJson({
        ..._music.toJson(), 'id': 'batch-$index', 'name': 'song $index',
      }),
    ], embed: _embed);
    await adapter.started.future;
    final ids = container.read(downloadProgressProvider).tasks.map((task) => task.id).toList();
    service.pauseAll();
    expect(container.read(downloadProgressProvider).tasks, hasLength(5));
    expect(container.read(downloadProgressProvider).tasks.every((t) => t.stage == DownloadStage.paused), isTrue);
    expect(await batch, isEmpty);
    await container.read(downloadProgressProvider.notifier).flushPersistence();
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(DownloadProgressNotifier.storageKey)!.map(
      (row) => jsonDecode(row) as Map<String, dynamic>,
    ).toList();
    expect(stored.map((row) => row['id']), ids);
    expect(stored.map((row) => row['stage']), everyElement('paused'));
    expect(pathCalls, isNot(contains('getApplicationDocumentsDirectory')));
    adapter.hold = false;
    await service.resumeAll();
    final completed = container.read(downloadProgressProvider).tasks;
    expect(completed.map((task) => task.id), ids);
    expect(completed.every((t) => t.stage == DownloadStage.done), isTrue);
    expect(completed.every((t) => File(t.savedPath!).existsSync()), isTrue);
    expect(pathCalls, isNot(contains('getApplicationDocumentsDirectory')));
  });

  test('concurrent downloads keep a writable requested directory without false fallback', () async {
    adapter.hold = false;
    final results = await service.downloadMany(musics: [
      for (var index = 0; index < 3; index++) MusicInfo.fromJson({
        ..._music.toJson(), 'id': 'probe-$index', 'name': 'probe $index',
      }),
    ], embed: _embed);
    expect(results, hasLength(3));
    expect(results.every((result) => result.success), isTrue);
    expect(adapter.calls, 3);
    expect(pathCalls, isNot(contains('getApplicationDocumentsDirectory')));
    expect(container.read(downloadProgressProvider).tasks.map((task) => task.stage),
      everyElement(DownloadStage.done));
    expect(results.map((result) => result.result!.path),
      everyElement(startsWith('${root.path}/music/')));
    final directoryEntries = await Directory('${root.path}/music').list().toList();
    expect(directoryEntries.whereType<Directory>(), isEmpty);
  });

  test('explicit quality, embed or destination changes download again; identical requests reuse', () async {
    adapter.hold = false;
    final first = await service.downloadOne(music: _music, quality: Quality.k128, embed: _embed);
    expect(adapter.calls, 1);
    final higher = await service.downloadOne(music: _music, quality: Quality.flac, embed: _embed);
    expect(adapter.calls, 2);
    expect(higher.path, isNot(first.path));
    const changedEmbed = EmbedRequest(embedCover: false, embedLyric: false,
      embedTranslatedLyric: false, embedRomanLyric: false, lyricFormat: EmbeddedLyricFormat.lrc);
    final embedded = await service.downloadOne(music: _music, quality: Quality.flac, embed: changedEmbed);
    expect(adapter.calls, 3);
    final otherDir = await Directory('${root.path}/other').create();
    await container.read(settingsProvider.notifier).setDownloadDir(otherDir.path);
    final relocated = await service.downloadOne(music: _music, quality: Quality.flac, embed: changedEmbed);
    expect(adapter.calls, 4);
    expect(relocated.path, startsWith('${otherDir.path}/'));
    expect(relocated.path, isNot(embedded.path));
    final reused = await service.downloadOne(music: _music, quality: Quality.flac, embed: changedEmbed);
    expect(reused.path, relocated.path);
    expect(adapter.calls, 4);
    await container.read(downloadProgressProvider.notifier).flushPersistence();
    container.invalidate(downloadProgressProvider);
    expect(container.read(downloadProgressProvider).tasks.every((t) => t.stage == DownloadStage.done), isTrue);
    await service.resumeAll();
    final restored = await service.downloadOne(music: _music, quality: Quality.flac, embed: changedEmbed);
    expect(restored.path, relocated.path);
    expect(adapter.calls, 4);
  });

  test('batch completion reuse also respects requested quality and destination', () async {
    adapter.hold = false;
    await service.downloadMany(musics: [_music], embed: _embed,
      qualityPreference: OnlinePlaybackQuality.highest);
    expect(adapter.calls, 1);
    final explicit = await service.downloadMany(musics: [_music], embed: _embed,
      qualityPreference: OnlinePlaybackQuality.standard);
    expect(explicit.single.success, isTrue);
    expect(adapter.calls, 2);
    final repeated = await service.downloadMany(musics: [_music], embed: _embed,
      qualityPreference: OnlinePlaybackQuality.standard);
    expect(repeated, isEmpty);
    expect(adapter.calls, 2);
    final otherDir = await Directory('${root.path}/batch-other').create();
    await container.read(settingsProvider.notifier).setDownloadDir(otherDir.path);
    final relocated = await service.downloadMany(musics: [_music], embed: _embed,
      qualityPreference: OnlinePlaybackQuality.standard);
    expect(relocated.single.result!.path, startsWith('${otherDir.path}/'));
    expect(adapter.calls, 3);
  });

  test('malformed recovered task cannot prevent an unrelated new download', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(DownloadProgressNotifier.storageKey, [jsonEncode({
      'id': 'corrupt', 'musicId': 'broken', 'name': 'broken', 'singer': 'artist',
      'stage': 'paused', 'music': {'id': 123}, 'embed': {},
    })]);
    container.invalidate(downloadProgressProvider);
    adapter.hold = false;
    final result = await service.downloadOne(music: _music, quality: Quality.k128, embed: _embed);
    expect(File(result.path).existsSync(), isTrue);
    expect(adapter.calls, 1);
    expect(container.read(downloadProgressProvider).tasks.map((t) => t.stage), [DownloadStage.done]);
  });

  test('invalid live task initialization fails its own row instead of leaving busy work', () async {
    final store = container.read(downloadProgressProvider.notifier);
    final id = store.enqueue(_music, embedOptions: {'cover': 'yes'});
    store.pause(id);
    await expectLater(service.resumeTask(id), throwsA(isA<TypeError>()));
    expect(container.read(downloadProgressProvider).tasks.single.stage, DownloadStage.failed);
    expect(container.read(downloadProgressProvider).isBusy, isFalse);
    adapter.hold = false;
    await service.downloadOne(music: _music, quality: Quality.k128, embed: _embed);
    expect(adapter.calls, 1);
  });

  test('invalid live music parsing marks its row failed and leaves unrelated downloads usable', () async {
    final malformed = MusicInfo(id: 'broken', name: 'broken', singer: 'artist',
      source: MusicSource.wy, interval: null, meta: _music.meta,
      raw: {..._music.toJson(), 'id': 123});
    final store = container.read(downloadProgressProvider.notifier);
    final id = store.enqueue(malformed);
    store.pause(id);
    await expectLater(service.resumeTask(id), throwsA(isA<TypeError>()));
    expect(container.read(downloadProgressProvider).tasks.single.stage, DownloadStage.failed);
    expect(container.read(downloadProgressProvider).isBusy, isFalse);
    adapter.hold = false;
    await service.downloadOne(music: _music, quality: Quality.k128, embed: _embed);
    expect(adapter.calls, 1);
  });

  test('a failed task retries on the same row without recording pause as failure', () async {
    adapter.hold = false;
    adapter.fail = true;
    await expectLater(service.downloadOne(music: _music, quality: Quality.k128, embed: _embed), throwsA(isA<Exception>()));
    final task = container.read(downloadProgressProvider).tasks.single;
    expect(task.stage, DownloadStage.failed);
    adapter.fail = false;
    await service.retryTask(task.id);
    expect(container.read(downloadProgressProvider).tasks.single.stage, DownloadStage.done);
  });
}

const _embed = EmbedRequest(embedCover: false, embedLyric: false, embedTranslatedLyric: false, embedRomanLyric: false);
final _music = MusicInfo.fromJson({'id': 'pause-song', 'name': 'song', 'singer': 'artist', 'source': 'wy', 'meta': {'songId': 'pause-song', 'albumName': '', 'qualitys': []}});

class _Adapter implements HttpClientAdapter {
  final started = Completer<void>();
  bool hold = true;
  bool fail = false;
  bool wasCancelled = false;
  int calls = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    calls++;
    if (!started.isCompleted) started.complete();
    if (hold) {
      await cancelFuture;
      wasCancelled = true;
      throw DioException(requestOptions: options, type: DioExceptionType.cancel);
    }
    return ResponseBody.fromBytes([0x49, 0x44, 0x33, 0x04, 0, 0], fail ? 500 : 200,
      headers: {Headers.contentLengthHeader: ['6'], Headers.contentTypeHeader: ['audio/mpeg']});
  }
  @override
  void close({bool force = false}) {}
}

class _Resolver implements MusicUrlResolver {
  @override
  Future<Quality> highestQualityFor(MusicInfo music) async => Quality.k128;
  @override
  Future<MusicUrl> resolve({required MusicInfo music, required Quality quality}) async => const MusicUrl(url: 'https://audio.invalid/file.mp3');
  @override
  Future<MusicSourceFallbackResult<T>> useFirstAvailable<T>({
    required MusicInfo music, required Quality quality, required MusicSourceUrlConsumer<T> use,
    Set<String> excludedSourceIds = const {}, bool Function()? isCancelled,
    bool Function(Object error)? shouldFallbackOnConsumerError,
  }) async {
    final source = MusicSourceRecord(
      id: 'test', name: 'Test', description: '', author: '', homepage: '', version: '1', origin: 'test',
      importedAt: DateTime(2026), updatedAt: DateTime(2026), capabilities: const {MusicSource.wy: [Quality.k128]},
    );
    final value = await use(source, const MusicUrl(url: 'https://audio.invalid/file.mp3', type: Quality.k128, fileName: 'file.mp3'));
    return MusicSourceFallbackResult(source: source, value: value, attemptedSourceIds: const ['test']);
  }
}
