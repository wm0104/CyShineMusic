import 'dart:convert';
import 'dart:io';

import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/downloads/download_progress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late ProviderContainer container;
  ProviderContainer open() => ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    container = open();
  });
  tearDown(() => container.dispose());

  test('pause invalidates old callbacks and resume uses a new generation', () async {
    final store = container.read(downloadProgressProvider.notifier);
    final id = store.start(_music);
    final first = container.read(downloadProgressProvider).tasks.single.generation;
    store.pause(id);
    store.finish(id, '/stale', generation: first);
    store.fail(id, 'old failure', generation: first);
    expect(container.read(downloadProgressProvider).tasks.single.stage, DownloadStage.paused);
    final second = store.restart(id);
    store.updateStage(id, DownloadStage.downloading, generation: first);
    store.fail(id, 'late', generation: first);
    expect(second, greaterThan(first));
    expect(container.read(downloadProgressProvider).tasks.single.stage, DownloadStage.resolvingUrl);
    store.finish(id, '/new', generation: second);
    expect(container.read(downloadProgressProvider).tasks.single.savedPath, '/new');
  });

  test('rebuilding restores busy and queued as paused, failures and completed files survive', () async {
    final file = await File('${Directory.systemTemp.path}/cyshine-done-test').writeAsString('audio');
    addTearDown(() => file.delete());
    final store = container.read(downloadProgressProvider.notifier);
    store.start(_music);
    store.enqueue(_music);
    final failed = store.start(_music);
    store.fail(failed, 'retry me');
    final done = store.start(_music);
    store.finish(done, file.path);
    await store.flushPersistence();
    container.dispose();
    container = open();
    final restored = container.read(downloadProgressProvider).tasks;
    expect(restored.map((t) => t.stage), [DownloadStage.paused, DownloadStage.paused, DownloadStage.failed, DownloadStage.done]);
    expect(restored.last.savedPath, file.path);
    expect(restored.first.musicJson, isNotNull);
    expect(restored.any((t) => t.isBusy), isFalse);
  });

  test('recovery isolates malformed music, quality and embed rows without hiding valid tasks', () async {
    final valid = <String, dynamic>{
      'id': 'valid', 'musicId': '1', 'name': 'song', 'singer': 'artist',
      'stage': 'queued', 'music': _music.toJson(), 'quality': '128k', 'embed': {},
    };
    final rows = <Map<String, dynamic>>[
      valid,
      {...valid, 'id': 'numeric-id', 'music': {..._music.toJson(), 'id': 123}},
      {...valid, 'id': 'missing-music', 'music': null},
      {...valid, 'id': 'empty-id', 'music': {..._music.toJson(), 'id': ' '}},
      {...valid, 'id': 'all', 'music': {..._music.toJson(), 'source': 'all'}},
      {...valid, 'id': 'unknown', 'music': {..._music.toJson(), 'source': 'unknown'}},
      {...valid, 'id': 'inconsistent', 'musicId': 'other'},
      {...valid, 'id': 'bad-quality', 'quality': 'unknown'},
      {...valid, 'id': 'bad-embed', 'embed': {'cover': 'yes'}},
      {...valid, 'id': 'null-embed', 'embed': {'lyric': null}},
      {...valid, 'id': 'bad-format', 'embed': {'format': 'unknown'}},
      {...valid, 'id': 'later-valid', 'stage': 'failed'},
    ];
    await prefs.setStringList(DownloadProgressNotifier.storageKey, rows.map(jsonEncode).toList());
    final tasks = container.read(downloadProgressProvider).tasks;
    expect(tasks.map((t) => t.id), ['valid', 'later-valid']);
    expect(tasks.map((t) => t.stage), [DownloadStage.paused, DownloadStage.failed]);
    expect(tasks.any((t) => t.isBusy), isFalse);
  });

  test('task storage excludes temporary playback URLs and secrets; byte callbacks do not change stored metadata', () async {
    final store = container.read(downloadProgressProvider.notifier);
    final music = MusicInfo.fromJson({
      ..._music.toJson(), 'url': 'https://temporary.invalid/audio?token=temporary-test',
      'authorization': 'test-only-secret',
      'meta': {'songId': '1', 'albumName': '', 'qualitys': [], 'picUrl': 'https://cover.invalid/stable.jpg'},
    });
    final id = store.start(music);
    await store.flushPersistence();
    final before = prefs.getStringList(DownloadProgressNotifier.storageKey)!;
    expect(before.join(), isNot(contains('temporary-test')));
    expect(before.join(), isNot(contains('test-only-secret')));
    expect(before.join(), contains('cover.invalid'));
    for (var index = 0; index < 1000; index++) { store.updateBytes(id, index, 1000); }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(prefs.getStringList(DownloadProgressNotifier.storageKey), before);
  });

  test('clearing completed tasks retains paused and failed retry records', () {
    final store = container.read(downloadProgressProvider.notifier);
    final paused = store.start(_music);
    store.pause(paused);
    final failed = store.start(_music);
    store.fail(failed, 'failed');
    store.clearFinished();
    expect(container.read(downloadProgressProvider).tasks.map((t) => t.id), [paused, failed]);
  });
}

final _music = MusicInfo.fromJson({
  'id': '1', 'name': 'song', 'singer': 'artist', 'source': 'wy',
  'meta': {'songId': '1', 'albumName': '', 'qualitys': []},
});
