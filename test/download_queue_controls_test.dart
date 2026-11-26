import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/services/download_service.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/downloads/download_progress.dart';
import 'package:cy_shine_music/features/downloads/download_queue_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('existing queue exposes per-row and all pause/continue/retry controls', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    late _Controls service;
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      downloadServiceProvider.overrideWith((ref) => service = _Controls(ref)),
    ]);
    addTearDown(container.dispose);
    final progress = container.read(downloadProgressProvider.notifier);
    final busy = progress.start(_music('busy'));
    final paused = progress.start(_music('paused'));
    progress.pause(paused);
    final failed = progress.start(_music('failed'));
    progress.fail(failed, 'failed');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () => showDownloadQueueSheet(context), child: const Text('open'),
      )))),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    for (final label in ['全部暂停', '全部继续']) {
      await tester.tap(find.text(label));
      await tester.pump();
    }
    for (final tooltip in ['暂停', '继续', '重试']) {
      await tester.ensureVisible(find.byTooltip(tooltip));
      await tester.tap(find.byTooltip(tooltip));
      await tester.pump();
    }
    expect(service.calls, ['pause-all', 'resume-all', 'pause:$busy', 'resume:$paused', 'retry:$failed']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

MusicInfo _music(String id) => MusicInfo.fromJson({
  'id': id, 'name': id, 'singer': 'artist', 'source': 'wy',
  'meta': {'songId': id, 'albumName': '', 'qualitys': []},
});

class _Controls extends DownloadService {
  _Controls(super.ref);
  final calls = <String>[];
  @override
  void pauseAll() => calls.add('pause-all');
  @override
  Future<void> resumeAll() async { calls.add('resume-all'); }
  @override
  void pauseTask(String id) => calls.add('pause:$id');
  @override
  Future<void> resumeTask(String id) async { calls.add('resume:$id'); }
  @override
  Future<void> retryTask(String id) async { calls.add('retry:$id'); }
}
