import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import '../../core/storage/settings_store.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/enums.dart';
import '../../core/models/lyric_format.dart';
import '../../core/models/music_info.dart';

enum DownloadStage {
  idle,
  queued,
  paused,
  resolvingUrl,
  downloading,
  fetchingMeta,
  tagging,
  finishing,
  done,
  failed,
}

class DownloadTask {
  const DownloadTask({
    required this.id,
    required this.musicId,
    required this.name,
    required this.singer,
    this.stage = DownloadStage.idle,
    this.received = 0,
    this.total,
    this.message,
    this.savedPath,
    this.musicJson,
    this.qualityCode,
    this.destinationDir,
    this.embedOptions = const {},
    this.generation = 0,
  });

  final String id;
  final String musicId;
  final String name;
  final String singer;
  final DownloadStage stage;
  final int received;
  final int? total;
  final String? message;
  final String? savedPath;
  final Map<String, dynamic>? musicJson;
  final String? qualityCode;
  final String? destinationDir;
  final Map<String, dynamic> embedOptions;
  final int generation;

  bool get isBusy =>
      stage != DownloadStage.idle &&
      stage != DownloadStage.paused &&
      stage != DownloadStage.done &&
      stage != DownloadStage.failed;

  double? get fraction {
    if (total == null || total! <= 0) return null;
    final value = received / total!;
    if (value.isNaN || value.isInfinite) return null;
    return value.clamp(0.0, 1.0);
  }

  DownloadTask copyWith({
    DownloadStage? stage,
    int? generation,
    int? received,
    Object? total = _sentinel,
    Object? message = _sentinel,
    Object? savedPath = _sentinel,
  }) {
    return DownloadTask(
      id: id,
      musicId: musicId,
      name: name,
      singer: singer,
      stage: stage ?? this.stage,
      generation: generation ?? this.generation,
      musicJson: musicJson,
      qualityCode: qualityCode,
      destinationDir: destinationDir,
      embedOptions: embedOptions,
      received: received ?? this.received,
      total: identical(total, _sentinel) ? this.total : total as int?,
      message: identical(message, _sentinel)
          ? this.message
          : message as String?,
      savedPath: identical(savedPath, _sentinel)
          ? this.savedPath
          : savedPath as String?,
    );
  }

  static const _sentinel = Object();
}

class DownloadProgress {
  const DownloadProgress({this.tasks = const []});

  final List<DownloadTask> tasks;

  DownloadTask? get activeTask {
    for (final task in tasks.reversed) {
      if (task.isBusy) return task;
    }
    return tasks.isNotEmpty ? tasks.last : null;
  }

  bool get hasTasks => tasks.isNotEmpty;
  bool get isBusy => tasks.any((task) => task.isBusy);

  DownloadTask? taskForMusic(String id) {
    for (final task in tasks.reversed) {
      if (task.musicId == id && task.isBusy) return task;
    }
    return null;
  }

  DownloadTask? latestTaskForMusic(String id) {
    for (final task in tasks.reversed) {
      if (task.musicId == id) return task;
    }
    return null;
  }

  bool isMusicBusy(String id) => taskForMusic(id) != null;
}

class DownloadProgressNotifier extends Notifier<DownloadProgress> {
  var _sequence = 0;
  SharedPreferences? _prefs;
  Future<void> _writes = Future.value();
  static const storageKey = 'download_tasks_v1';

  Future<void> flushPersistence() => _writes;

  void _persist() {
    final rows = [for (final t in state.tasks) jsonEncode({
      'id': t.id, 'musicId': t.musicId, 'name': t.name, 'singer': t.singer,
      'stage': t.stage.name, 'savedPath': t.savedPath,
      'message': t.message?.replaceAll(RegExp(r'https?://[^\s]+'), '[地址已省略]'),
      'music': t.musicJson, 'quality': t.qualityCode, 'embed': t.embedOptions,
      'destinationDir': t.destinationDir,
      'generation': t.generation,
    })];
    // Update SharedPreferences' in-memory cache immediately, including when
    // the notifier is rebuilt in the same turn. Byte callbacks never call this.
    final write = _prefs?.setStringList(storageKey, rows).then<void>((saved) {
      if (!saved) throw StateError('无法保存下载任务');
    }) ?? Future<void>.value();
    _writes = Future.wait<void>([_writes.catchError((Object _) {}), write])
        .then<void>((_) {});
    // Callers may await flushPersistence; unattached writes must not become an
    // unhandled async exception when a storage plugin reports a failure.
    unawaited(_writes.catchError((Object _) {}));
  }


  /// dio's onReceiveProgress fires on every received chunk — hundreds of
  /// times per second on a fast link. Emitting state that often starves the
  /// raster thread, so byte updates are coalesced to one emission per
  /// interval (leading edge immediate, trailing edge via timer).
  static const _bytesFlushInterval = Duration(milliseconds: 100);
  final Map<String, ({int received, int? total})> _pendingBytes = {};
  Timer? _bytesFlushTimer;

  @override
  DownloadProgress build() {
    ref.onDispose(() {
      _bytesFlushTimer?.cancel();
      _bytesFlushTimer = null;
      _pendingBytes.clear();
    });
    // Older unit callers may construct this provider without an application
    // preferences override; normal app startup always supplies it.
    try { _prefs = ref.read(sharedPreferencesProvider); } on UnimplementedError { _prefs = null; }
    final tasks = <DownloadTask>[];
    for (final row in _prefs?.getStringList(storageKey) ?? const <String>[]) {
      try {
        final json = jsonDecode(row) as Map<String, dynamic>;
        final musicJson = Map<String, dynamic>.from(json['music'] as Map);
        final music = MusicInfo.fromJson(musicJson);
        final quality = json['quality'] as String?;
        final embed = Map<String, dynamic>.from(json['embed'] as Map? ?? {});
        if (music.id.trim().isEmpty || music.source == MusicSource.all ||
            json['musicId'] != music.id ||
            (json['id'] as String).trim().isEmpty ||
            (quality != null && Quality.tryFromCode(quality) == null) ||
            ['cover', 'lyric', 'translated', 'roman'].any((key) =>
              embed.containsKey(key) && embed[key] is! bool) ||
            (embed.containsKey('format') && !EmbeddedLyricFormat.values.any(
              (format) => format.code == embed['format']))) {
          throw const FormatException('下载任务记录无效');
        }
        final stored = DownloadStage.values.byName(json['stage'] as String);
        final stage = stored == DownloadStage.done || stored == DownloadStage.failed
            ? stored : DownloadStage.paused;
        tasks.add(DownloadTask(
          id: json['id'] as String, musicId: json['musicId'] as String,
          name: json['name'] as String, singer: json['singer'] as String,
          stage: stage, savedPath: json['savedPath'] as String?,
          message: stage == DownloadStage.paused ? null : json['message'] as String?,
          musicJson: musicJson,
          qualityCode: quality,
          destinationDir: json['destinationDir'] as String?,
          embedOptions: embed,
          generation: (json['generation'] as int? ?? 0) + 1,
        ));
      } catch (_) { /* A damaged task must not hide the remaining queue. */ }
    }
    return DownloadProgress(tasks: tasks);
  }

  String start(MusicInfo music) => enqueue(music, stage: DownloadStage.resolvingUrl);

  String enqueue(MusicInfo music, {
    DownloadStage stage = DownloadStage.queued,
    String? qualityCode,
    String? destinationDir,
    Map<String, dynamic> embedOptions = const {},
  }) {
    final taskId =
        '${music.id}-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
    final task = DownloadTask(
      id: taskId,
      musicId: music.id,
      name: music.name,
      singer: music.singer,
      stage: stage,
      musicJson: _safeMusicJson(music),
      qualityCode: qualityCode,
      destinationDir: destinationDir,
      embedOptions: embedOptions,
    );
    state = DownloadProgress(tasks: [...state.tasks, task]);
    _persist();
    return task.id;
  }

  void updateStage(String id, DownloadStage stage, {String? message, int? generation}) {
    _update(id, (task) => task.copyWith(stage: stage, message: message), generation: generation);
  }

  void pause(String id, {int? generation}) {
    _pendingBytes.remove(id);
    _update(id, (task) => task.copyWith(stage: DownloadStage.paused,
      generation: task.generation + 1, message: null), generation: generation);
  }

  int restart(String id) {
    _pendingBytes.remove(id);
    final index = state.tasks.indexWhere((t) => t.id == id);
    if (index < 0) throw StateError('下载任务不存在');
    final next = [...state.tasks];
    final task = next[index];
    if (task.stage == DownloadStage.done) return task.generation;
    next[index] = task.copyWith(stage: DownloadStage.resolvingUrl,
      generation: task.generation + 1, received: 0, total: null, message: null);
    state = DownloadProgress(tasks: next);
    _persist();
    return next[index].generation;
  }

  void updateBytes(String id, int received, int? total, {int? generation}) {
    if (!state.tasks.any((t) => t.id == id && t.isBusy && (generation == null || t.generation == generation))) return;
    _pendingBytes[id] = (received: received, total: total);
    if (_bytesFlushTimer != null) return;
    _flushPendingBytes();
    _bytesFlushTimer = Timer(_bytesFlushInterval, _onBytesFlushTimer);
  }

  void _onBytesFlushTimer() {
    _bytesFlushTimer = null;
    if (_pendingBytes.isEmpty) return;
    _flushPendingBytes();
    _bytesFlushTimer = Timer(_bytesFlushInterval, _onBytesFlushTimer);
  }

  void _flushPendingBytes() {
    if (_pendingBytes.isEmpty) return;
    final updates = Map.of(_pendingBytes);
    _pendingBytes.clear();
    final next = [...state.tasks];
    var changed = false;
    for (final entry in updates.entries) {
      final index = next.lastIndexWhere(
        (task) => task.id == entry.key && task.isBusy,
      );
      if (index < 0) continue;
      next[index] = next[index].copyWith(
        received: entry.value.received,
        total: entry.value.total,
      );
      changed = true;
    }
    if (changed) state = DownloadProgress(tasks: next);
  }

  void finish(String id, String savedPath, {int? generation}) {
    if (generation != null && !state.tasks.any((t) => t.id == id && t.isBusy && t.generation == generation)) return;
    _pendingBytes.remove(id);
    _update(
      id,
      (task) => task.copyWith(
        stage: DownloadStage.done,
        savedPath: savedPath,
        message: null,
      ),
      generation: generation,
    );
  }

  void fail(String id, String message, {int? generation}) {
    if (generation != null && !state.tasks.any((t) => t.id == id && t.isBusy && t.generation == generation)) return;
    _pendingBytes.remove(id);
    _update(
      id,
      (task) => task.copyWith(stage: DownloadStage.failed, message: message),
      generation: generation,
    );
  }

  void reset() {
    _pendingBytes.clear();
    state = const DownloadProgress();
    _persist();
  }

  void clearFinished() {
    state = DownloadProgress(
      tasks: state.tasks.where((task) => task.stage != DownloadStage.done).toList(),
    );
    _persist();
  }

  void remove(String id) {
    state = DownloadProgress(
      tasks: state.tasks.where((task) => task.id != id || task.isBusy).toList(),
    );
    _persist();
  }

  void _update(String id, DownloadTask Function(DownloadTask task) update, {int? generation}) {
    final index = state.tasks.lastIndexWhere(
      (task) => task.id == id && task.isBusy && (generation == null || task.generation == generation),
    );
    if (index < 0) return;
    final next = [...state.tasks];
    next[index] = update(next[index]);
    state = DownloadProgress(tasks: next);
    _persist();
  }
}

final downloadProgressProvider =
    NotifierProvider<DownloadProgressNotifier, DownloadProgress>(
      DownloadProgressNotifier.new,
    );

String describeStage(DownloadStage stage) {
  switch (stage) {
    case DownloadStage.queued:
      return '等待下载';
    case DownloadStage.paused:
      return '已暂停';
    case DownloadStage.idle:
      return '空闲';
    case DownloadStage.resolvingUrl:
      return '解析下载地址';
    case DownloadStage.downloading:
      return '下载中';
    case DownloadStage.fetchingMeta:
      return '获取封面与歌词';
    case DownloadStage.tagging:
      return '写入标签';
    case DownloadStage.finishing:
      return '移动到下载目录';
    case DownloadStage.done:
      return '完成';
    case DownloadStage.failed:
      return '失败';
  }
}

// Temporary playback URLs and script credentials do not belong in task storage.
Map<String, dynamic> _safeMusicJson(MusicInfo music) {
  Object? clean(Object? value) {
    if (value is List) return value.map(clean).toList();
    if (value is Map) return <String, dynamic>{
      for (final entry in value.entries)
        if (!RegExp(r'^(?:url|play_?url|playback_?url|audio_?url|music_?url)$|token|password|authorization|cookie', caseSensitive: false).hasMatch(entry.key.toString()))
          entry.key.toString(): clean(entry.value),
    };
    return value;
  }
  return Map<String, dynamic>.from(clean(music.toJson()) as Map);
}
