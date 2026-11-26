import 'dart:io';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../features/downloads/download_progress.dart';
import '../../features/downloads/download_history_store.dart';
import '../../features/playlists/playlist_store.dart';
import '../api/api_client.dart';
import '../api/music_api.dart';
import '../models/enums.dart';
import '../models/lyric_format.dart';
import '../models/music_info.dart';
import '../music_sources/music_url_resolver.dart';
import '../storage/settings_store.dart';
import '../ui/cover_image_source.dart';
import 'app_logger.dart';
import 'file_naming.dart';
import 'lyric_builder.dart';
import 'permission_service.dart';
import 'tagger.dart';

class EmbedRequest {
  const EmbedRequest({
    this.embedCover = true,
    this.embedLyric = true,
    this.embedTranslatedLyric = true,
    this.embedRomanLyric = true,
    this.lyricFormat = EmbeddedLyricFormat.automatic,
  });

  const EmbedRequest.richest()
    : embedCover = true,
      embedLyric = true,
      embedTranslatedLyric = true,
      embedRomanLyric = true,
      lyricFormat = EmbeddedLyricFormat.automatic;

  final bool embedCover;
  final bool embedLyric;
  final bool embedTranslatedLyric;
  final bool embedRomanLyric;
  final EmbeddedLyricFormat lyricFormat;

  bool get needsMetadata =>
      embedCover || embedLyric || embedTranslatedLyric || embedRomanLyric;
}

class DownloadResult {
  const DownloadResult({required this.path});
  final String path;
}

class DownloadSourceFallbackException implements Exception {
  const DownloadSourceFallbackException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BatchDownloadResult {
  const BatchDownloadResult({required this.music, this.result, this.error});

  final MusicInfo music;
  final DownloadResult? result;
  final Object? error;

  bool get success => result != null;
}

class DownloadService {
  DownloadService(this._ref) {
    final progressStore = _ref.read(downloadProgressProvider.notifier);
    var lastTasks = _ref.read(downloadProgressProvider).tasks;
    _ref.listen<DownloadProgress>(downloadProgressProvider, (_, next) {
      lastTasks = next.tasks;
      for (final entry in _running.entries) {
        DownloadTask? current;
        for (final task in next.tasks) {
          if (task.id == entry.key) { current = task; break; }
        }
        if (current == null || current.stage == DownloadStage.paused ||
            current.generation != _runningGenerations[entry.key]) {
          entry.value.cancel('stale generation');
        }
      }
    });
    _ref.onDispose(() {
      _disposed = true;
      for (final token in _running.values) { token.cancel('disposed'); }
      for (final job in _waiting) { job.result.completeError(const DownloadPausedException()); }
      _waiting.clear();
      final orphaned = lastTasks.where((task) => task.isBusy && task.stage != DownloadStage.finishing).toList();
      // A service-only invalidation keeps the progress notifier alive. Defer
      // its update outside Riverpod disposal; a whole-container shutdown may
      // already have disposed the notifier, in which case disk recovery wins.
      scheduleMicrotask(() {
        for (final task in orphaned) {
          try { progressStore.pause(task.id, generation: task.generation); }
          catch (_) { /* Progress was disposed together with the container. */ }
        }
      });
    });
  }

  final Ref _ref;
  static const _mediaScanChannel = MethodChannel('cy_shine_music/media_scan');
  static const int batchConcurrency = 3;

  final Set<String> _batchDownloadKeys = {};
  final Map<String, String> _preparedTasks = {};
  final Map<String, MusicInfo> _originalMusic = {};
  final Map<String, CancelToken> _running = {};
  final Map<String, int> _runningGenerations = {};
  final List<({String id, int generation, Completer<DownloadResult> result})> _waiting = [];
  bool _disposed = false;

  DownloadTask? _task(String id) {
    for (final task in _ref.read(downloadProgressProvider).tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  void pauseTask(String id) {
    final task = _task(id);
    // File export is a short, committed operation: don't interrupt its rename.
    if (task == null || !task.isBusy || task.stage == DownloadStage.finishing) return;
    _ref.read(downloadProgressProvider.notifier).pause(id);
    _running[id]?.cancel('paused');
    _pump();
  }

  void pauseAll() {
    for (final task in [..._ref.read(downloadProgressProvider).tasks]) {
      pauseTask(task.id);
    }
  }

  Future<void> resumeTask(String id) async {
    final task = _task(id);
    if (task == null || task.stage != DownloadStage.paused) return;
    _ref.read(downloadProgressProvider.notifier).restart(id);
    try { await _schedule(id); } on DownloadPausedException { return; }
  }

  Future<void> retryTask(String id) async {
    final task = _task(id);
    if (task == null || task.stage != DownloadStage.failed) return;
    _ref.read(downloadProgressProvider.notifier).restart(id);
    try { await _schedule(id); } on DownloadPausedException { return; }
  }

  Future<void> resumeAll() async {
    final ids = [for (final t in _ref.read(downloadProgressProvider).tasks)
      if (t.stage == DownloadStage.paused) t.id];
    await Future.wait(ids.map(resumeTask));
  }

  Future<DownloadResult> _schedule(String id) {
    final result = Completer<DownloadResult>();
    _waiting.add((id: id, generation: _task(id)!.generation, result: result));
    _ref.read(downloadProgressProvider.notifier).updateStage(id, DownloadStage.queued);
    _pump();
    return result.future;
  }

  void _pump() {
    if (_disposed) return;
    while (_running.length < batchConcurrency && _waiting.isNotEmpty) {
      final index = _waiting.indexWhere((job) => !_running.containsKey(job.id));
      if (index < 0) return;
      final job = _waiting.removeAt(index);
      final task = _task(job.id);
      if (task == null || !task.isBusy || task.generation != job.generation) {
        job.result.completeError(const DownloadPausedException());
        continue;
      }
      final token = CancelToken();
      _running[job.id] = token;
      _runningGenerations[job.id] = task.generation;
      _runTask(task, token).then(job.result.complete, onError: job.result.completeError)
        .whenComplete(() {
          _running.remove(job.id);
          _runningGenerations.remove(job.id);
          _pump();
        });
    }
  }


  Future<List<BatchDownloadResult>> downloadMany({
    required List<MusicInfo> musics,
    EmbedRequest embed = const EmbedRequest.richest(),
    int concurrency = batchConcurrency,
    OnlinePlaybackQuality qualityPreference = OnlinePlaybackQuality.highest,
  }) async {
    if (musics.isEmpty) return const [];

    final busyMusicIds = {
      for (final task in _ref.read(downloadProgressProvider).tasks)
        if (task.isBusy && task.musicId.trim().isNotEmpty) task.musicId.trim(),
    };
    final seen = <String>{};
    final pending = <({String key, MusicInfo music, String taskId})>[];
    for (final music in musics) {
      final key = _batchDownloadKey(music);
      final musicId = music.id.trim();
      if (!seen.add(key) ||
          (musicId.isNotEmpty && busyMusicIds.contains(musicId)) ||
          !_batchDownloadKeys.add(key)) {
        continue;
      }
      final destinationDir = _ref.read(settingsProvider).downloadDir;
      final quality = _batchQualityFor(music, qualityPreference);
      if (_ref.read(downloadProgressProvider).tasks.any((task) =>
          _canReuseCompleted(task, key, quality, embed, destinationDir))) {
        _batchDownloadKeys.remove(key);
        continue;
      }
      final taskId = _ref.read(downloadProgressProvider.notifier).enqueue(
        music, qualityCode: quality?.code,
        destinationDir: destinationDir, embedOptions: _embedJson(embed),
      );
      _originalMusic[taskId] = music;
      pending.add((key: key, music: music, taskId: taskId));
    }
    if (pending.isEmpty) return const [];

    final results = List<BatchDownloadResult?>.filled(pending.length, null);
    final workerCount = concurrency
        .clamp(1, batchConcurrency)
        .clamp(1, pending.length);
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final index = nextIndex;
        nextIndex += 1;
        if (index >= pending.length) return;
        final job = pending[index];
        try {
          if (_task(job.taskId)?.stage != DownloadStage.queued) {
            throw const DownloadPausedException();
          }
          _preparedTasks[job.key] = job.taskId;
          final quality = _batchQualityFor(job.music, qualityPreference);
          final result = await downloadOne(
            music: job.music,
            quality: quality,
            embed: embed,
          );
          results[index] = BatchDownloadResult(
            music: job.music,
            result: result,
          );
        } catch (error) {
          results[index] = BatchDownloadResult(music: job.music, error: error);
        } finally {
          _preparedTasks.remove(job.key);
          _batchDownloadKeys.remove(job.key);
        }
      }
    }

    try {
      await Future.wait(List.generate(workerCount, (_) => worker()));
    } finally {
      for (final job in pending) {
        _batchDownloadKeys.remove(job.key);
      }
    }
    return results.whereType<BatchDownloadResult>()
        .where((item) => item.error is! DownloadPausedException)
        .toList(growable: false);
  }

  Quality? _batchQualityFor(MusicInfo music, OnlinePlaybackQuality preference) {
    if (preference.preferredQuality == null) return null;
    return music.playbackQualityFor(preference);
  }

  String _batchDownloadKey(MusicInfo music) {
    final source = music.source.code;
    final id = music.id.trim();
    if (id.isNotEmpty) return '$source\u0000$id';
    return '$source\u0000${music.name.trim().toLowerCase()}'
        '\u0000${music.singer.trim().toLowerCase()}';
  }

  bool _taskMatchesMusic(DownloadTask task, String key) {
    try {
      return task.musicJson != null &&
          _batchDownloadKey(MusicInfo.fromJson(task.musicJson!)) == key;
    } catch (_) {
      return false;
    }
  }

  bool _canReuseCompleted(DownloadTask task, String key, Quality? quality,
      EmbedRequest embed, String destinationDir) =>
      task.stage == DownloadStage.done && _taskMatchesMusic(task, key) &&
      task.qualityCode == quality?.code && task.destinationDir == destinationDir &&
      mapEquals(task.embedOptions, _embedJson(embed)) &&
      task.savedPath != null && File(task.savedPath!).existsSync();

  Future<DownloadResult> downloadOne({
    required MusicInfo music,
    Quality? quality,
    required EmbedRequest embed,
  }) async {
    final key = _batchDownloadKey(music);
    final prepared = _preparedTasks.remove(key);
    if (prepared != null) return _schedule(prepared);
    final destinationDir = _ref.read(settingsProvider).downloadDir;
    for (final task in _ref.read(downloadProgressProvider).tasks.reversed) {
      if (!_taskMatchesMusic(task, key)) continue;
      if (_canReuseCompleted(task, key, quality, embed, destinationDir)) {
        return DownloadResult(path: task.savedPath!);
      }
      if (task.isBusy) throw StateError('歌曲已在下载队列中');
    }
    final id = _ref.read(downloadProgressProvider.notifier).enqueue(
      music, qualityCode: quality?.code, destinationDir: destinationDir,
      embedOptions: _embedJson(embed),
    );
    _originalMusic[id] = music;
    return _schedule(id);
  }

  Future<DownloadResult> _runTask(DownloadTask task, CancelToken token) async {
    final progress = _ref.read(downloadProgressProvider.notifier);
    final taskId = task.id;
    final generation = task.generation;
    MusicInfo? failedMusic;
    Quality? selectedQuality;
    void check() {
      if (_disposed || token.isCancelled || _task(taskId)?.generation != generation ||
          _task(taskId)?.isBusy != true) throw const DownloadPausedException();
    }
    void stage(DownloadStage value, {String? message}) {
      check();
      progress.updateStage(taskId, value, message: message, generation: generation);
    }
    void log(String msg) {
      AppLogger.write('download', msg);
    }

    Directory? taskCacheDir;
    try {
      check();
      final music = _originalMusic[taskId] ?? MusicInfo.fromJson(task.musicJson!);
      failedMusic = music;
      final quality = task.qualityCode == null ? null : Quality.tryFromCode(task.qualityCode!);
      if (music.id.trim().isEmpty || music.source == MusicSource.all ||
          (task.qualityCode != null && quality == null)) {
        throw const FormatException('下载任务记录无效');
      }
      selectedQuality = quality;
      final embed = _embedFromJson(task.embedOptions);
      final api = _ref.read(musicApiProvider);
      final dio = _ref.read(apiClientProvider);
      final settings = _ref.read(settingsProvider);
      stage(DownloadStage.resolvingUrl);
      final resolver = _ref.read(musicUrlResolverProvider);
      final requestedQuality = selectedQuality ??= await resolver
          .highestQualityFor(music);
      check();
      log('==== NEW DOWNLOAD ====');
      log(
        'start ${music.source.code} "${music.name} - ${music.singer}" '
        'quality=${requestedQuality.code} '
        'qualityMode=${quality == null ? "source-highest" : "explicit"} '
        'lyricFormat=${embed.lyricFormat.code}',
      );

      // Resolve and transfer inside the same source attempt so a stale CDN
      // URL can fall through to the next enabled source.
      log('step1 resolve with enabled local music sources');
      final destDir = await _resolveDestinationDir(task.destinationDir ?? settings.downloadDir, log);
      final cacheRoot = await getTemporaryDirectory();
      taskCacheDir = await cacheRoot.createTemp('cyshine-download-');
      check();

      final MusicSourceFallbackResult<_DownloadedAudio> sourceResult;
      try {
        sourceResult = await resolver.useFirstAvailable<_DownloadedAudio>(
          music: music,
          quality: requestedQuality,
          isCancelled: () => _disposed || token.isCancelled || _task(taskId)?.generation != generation,
          shouldFallbackOnConsumerError: (error) {
            check();
            return _shouldFallbackAfterDownloadError(error);
          },
          use: (source, musicUrl) async {
            check();
            if (musicUrl.url.trim().isEmpty) {
              throw Exception('音源未返回音频地址');
            }
            final resolvedQuality = musicUrl.type ?? requestedQuality;
            final extension = FileNaming.extensionFor(
              requestedQuality,
              resolvedQuality,
            );
            final fileName = FileNaming.resolvedOrBuild(
              music,
              extension,
              musicUrl.fileName,
            );
            final candidateTmpPath = p.join(taskCacheDir!.path, fileName);

            stage(
              DownloadStage.downloading,
              message: '正在尝试音源：${source.name}',
            );
            progress.updateBytes(taskId, 0, null, generation: generation);
            log(
              'step1 OK source=${source.name} url.len=${musicUrl.url.length} '
              'type=${musicUrl.type}',
            );
            log('step2 destDir=${destDir.path} fileName=$fileName');
            log('step3 GET source=${source.name} ${_shortUrl(musicUrl.url)}');
            try {
              await dio.download(
                musicUrl.url,
                candidateTmpPath,
                cancelToken: token,
                options: Options(
                  headers: const {
                    'User-Agent':
                        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                        'AppleWebKit/537.36 (KHTML, like Gecko) '
                        'Chrome/120.0.0.0 Safari/537.36',
                  },
                  responseType: ResponseType.bytes,
                ),
                onReceiveProgress: (received, total) {
                  progress.updateBytes(
                    taskId,
                    received,
                    total > 0 ? total : null,
                    generation: generation,
                  );
                },
              );
            } catch (error) {
              log('step3 FAIL source=${source.name}: $error');
              if (error is DioException) {
                log(
                  'step3 dio: type=${error.type} message=${error.message} '
                  'status=${error.response?.statusCode}',
                );
              }
              await _deleteTemporaryFile(candidateTmpPath);
              rethrow;
            }
            check();
            log('step3 OK source=${source.name} bytes downloaded to tmp');
            return _DownloadedAudio(
              tmpPath: candidateTmpPath,
              fileName: fileName,
              quality: resolvedQuality,
            );
          },
        );
      } on MusicSourceFallbackException catch (error) {
        throw _downloadFallbackException(error);
      } catch (e) {
        log('step1/3 FAIL: $e');
        if (e is DioException) {
          log(
            'step1/3 dio: type=${e.type} message=${e.message} '
            'status=${e.response?.statusCode} body=${e.response?.data}',
          );
        }
        rethrow;
      }
      check();
      final downloaded = sourceResult.value;
      final tmpPath = downloaded.tmpPath;
      final fileName = downloaded.fileName;
      final resolvedQuality = downloaded.quality;

      // 4. Embed core tags plus any cover/lyrics fetched on-device.
      Uint8List? coverBytes;
      String? finalLyric;
      if (embed.needsMetadata) {
        stage(DownloadStage.fetchingMeta);
        if (embed.embedCover) {
          coverBytes = await _fetchCoverBytes(api, dio, music, log, cancelToken: token);
          log('step4 cover bytes=${coverBytes?.length ?? 0}');
        }

        if (embed.embedLyric ||
            embed.embedTranslatedLyric ||
            embed.embedRomanLyric) {
          try {
            final lyricInfo = await api.getLyric(musicInfo: music);
            log(
              'step4 lyric parts lrc=${lyricInfo.lyric.length} '
              'word=${lyricInfo.lxlyric?.length ?? 0} '
              'tlrc=${lyricInfo.tlyric?.length ?? 0} '
              'rlrc=${lyricInfo.rlyric?.length ?? 0}',
            );
            finalLyric = LyricBuilder.build(
              lyricInfo,
              LyricEmbedOptions(
                embedLyric: embed.embedLyric,
                embedTranslatedLyric: embed.embedTranslatedLyric,
                embedRomanLyric: embed.embedRomanLyric,
                format: embed.lyricFormat,
                source: music.source,
              ),
            );
            if (finalLyric.isEmpty) finalLyric = null;
            log('step4 lyric length=${finalLyric?.length ?? 0}');
          } catch (e) {
            log('step4 lyric FAIL: $e');
            finalLyric = null;
          }
        }
      }

      // Title/artist/album are always written. A temporary lyric or cover
      // failure must not leave a downloaded audio file completely untagged.
      stage(DownloadStage.tagging);
      log(
        'step4 tagging start cover=${coverBytes?.length ?? 0} '
        'lyric=${finalLyric?.length ?? 0}',
      );
      try {
        final verify = await Tagger.write(
          tmpPath,
          TaggingPayload(
            title: music.name,
            artist: music.singer,
            album: music.albumName,
            coverBytes: coverBytes,
            lyrics: finalLyric,
          ),
        );
        log(
          'step4 tagging OK verifyLyrics=${verify?.lyricsLength ?? -1} '
          'verifyCover=${verify?.artworkLength ?? -1}',
        );
        // Surface verify gaps to the UI so silent "no cover/lyric" bugs stop
        // being silent. A null result means the verify read itself failed.
        if (verify != null) {
          final wantedLyric = finalLyric != null && finalLyric.isNotEmpty;
          final wantedCover = coverBytes != null && coverBytes.isNotEmpty;
          final lyricBroken = wantedLyric && verify.lyricsLength == 0;
          final coverBroken = wantedCover && verify.artworkLength == 0;
          if (lyricBroken || coverBroken) {
            final parts = <String>[];
            if (lyricBroken) parts.add('歌词');
            if (coverBroken) parts.add('封面');
            stage(
              DownloadStage.tagging,
              message: '${parts.join('、')}标签写入失败',
            );
          }
        }
      } catch (e, s) {
        log('step4 tagging FAIL, keep raw audio: $e');
        log('step4 stack: $s');
        stage(
          DownloadStage.tagging,
          message: '标签写入失败：$e（音频本身正常）',
        );
      }

      // 5. Move to user-visible directory + trigger MediaScanner.
      stage(DownloadStage.finishing);
      final finalPath = await _moveToTarget(tmpPath, destDir, fileName);
      await _scanMedia(finalPath);

      log('DONE $finalPath');
      progress.finish(taskId, finalPath, generation: generation);
      await _recordCompleted(music, resolvedQuality, finalPath, log);
      await _attachDownload(music, resolvedQuality, finalPath, log);
      return DownloadResult(path: finalPath);
    } catch (e, s) {
      if (_disposed || token.isCancelled || e is DownloadPausedException ||
          _task(taskId)?.generation != generation) {
        throw const DownloadPausedException();
      }
      log('FAILED at outer catch: $e');
      log('stack: $s');
      progress.fail(taskId, _messageFor(e), generation: generation);
      if (failedMusic != null) {
        await _recordFailed(
          failedMusic,
          selectedQuality ?? failedMusic.bestQuality,
          _messageFor(e),
          log,
        );
      }
      rethrow;
    } finally {
      if (taskCacheDir != null) {
        try {
          if (taskCacheDir.existsSync()) {
            await taskCacheDir.delete(recursive: true);
          }
        } catch (_) {}
      }
    }
  }

  Future<Uint8List?> _fetchCoverBytes(
    MusicApi api,
    Dio dio,
    MusicInfo music,
    void Function(String) log, {
    CancelToken? cancelToken,
  }) async {
    String? picUrl;
    try {
      picUrl = await api.getPicUrl(musicInfo: music);
      log('step4 cover url from api=${_shortUrl(picUrl)}');
    } catch (e) {
      log('step4 cover api FAIL: $e');
      picUrl = music.meta.picUrl;
      log('step4 cover fallback meta=${_shortUrl(picUrl)}');
    }
    if (picUrl == null || picUrl.isEmpty) {
      log('step4 cover skip: empty url');
      return null;
    }
    picUrl = CoverImageSource.normalizeUrl(picUrl, size: 500);
    if (picUrl == null || picUrl.isEmpty) {
      log('step4 cover skip: normalized empty url');
      return null;
    }
    try {
      final headers = <String, String>{
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        ...?CoverImageSource.headersFor(picUrl),
      };
      final resp = await dio.get<List<int>>(
        picUrl,
        cancelToken: cancelToken,
        options: Options(responseType: ResponseType.bytes, headers: headers),
      );
      final bytes = Uint8List.fromList(resp.data ?? const []);
      final contentType = resp.headers.value('content-type') ?? '';
      log(
        'step4 cover GET OK status=${resp.statusCode} '
        'contentType=$contentType bytes=${bytes.length}',
      );
      if (bytes.isEmpty) return null;
      final detectedMimeType = imageMimeTypeFromBytes(bytes);
      if (detectedMimeType == null) {
        log('step4 cover rejected: response is not a supported image');
        return null;
      }
      log('step4 cover detectedMimeType=$detectedMimeType');
      return bytes;
    } catch (e) {
      log('step4 cover GET FAIL: $e');
      return null;
    }
  }

  String _shortUrl(String? url) {
    if (url == null || url.isEmpty) return '';
    return url.length > 160 ? '${url.substring(0, 160)}...' : url;
  }

  bool _shouldFallbackAfterDownloadError(Object error) {
    if (error is FileSystemException) return false;
    if (error is DioException && error.error is FileSystemException) {
      return false;
    }
    return true;
  }

  DownloadSourceFallbackException _downloadFallbackException(
    MusicSourceFallbackException error,
  ) {
    if (error.failures.isEmpty) {
      return const DownloadSourceFallbackException('没有更多可用的备用音源');
    }
    final last = error.failures.last;
    return DownloadSourceFallbackException(
      '所有已启用音源均无法下载这首歌（已尝试 ${error.failures.length} 个）：'
      '${last.source.name}：${_messageFor(last.error)}',
    );
  }

  Future<void> _deleteTemporaryFile(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    } catch (_) {}
  }

  Future<Directory> _resolveDestinationDir(
    String requested,
    void Function(String) log,
  ) async {
    final dir = Directory(requested);
    try {
      if (!dir.existsSync()) {
        log('destDir does not exist, creating: ${dir.path}');
        await PermissionService.ensureExternalStorageWrite();
        await dir.create(recursive: true);
      }
      // Each concurrent task needs its own probe; sharing a filename makes
      // another task's successful cleanup look like a permission failure.
      final probeDir = await dir.createTemp('.cyshine-probe-');
      try {
        await File(p.join(probeDir.path, 'write')).writeAsString('ok');
      } finally {
        await probeDir.delete(recursive: true);
      }
      return dir;
    } catch (e) {
      log('destDir FAILED ${dir.path}: $e; falling back to app-private');
      final fallback = await getApplicationDocumentsDirectory();
      final fb = Directory(p.join(fallback.path, 'CyShineMusic'));
      if (!fb.existsSync()) fb.createSync(recursive: true);
      return fb;
    }
  }

  Future<String> _moveToTarget(
    String tmpPath,
    Directory destDir,
    String fileName,
  ) async {
    final destPath = p.join(destDir.path, _dedupedName(destDir, fileName));
    final tmp = File(tmpPath);
    try {
      return (await tmp.rename(destPath)).path;
    } on FileSystemException {
      // rename fails across fs boundaries (sdcard → emulated); copy instead.
      await tmp.copy(destPath);
      await tmp.delete();
      return destPath;
    }
  }

  String _dedupedName(Directory dir, String fileName) {
    final base = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    var attempt = fileName;
    var i = 1;
    while (File(p.join(dir.path, attempt)).existsSync()) {
      attempt = '$base ($i)$ext';
      i += 1;
    }
    return attempt;
  }

  Future<void> _scanMedia(String path) async {
    if (!Platform.isAndroid) return;
    try {
      await _mediaScanChannel.invokeMethod('scan', {'path': path});
    } catch (_) {
      // Best-effort: media library will reindex eventually.
    }
  }

  Future<void> _recordCompleted(
    MusicInfo music,
    Quality quality,
    String savedPath,
    void Function(String) log,
  ) async {
    try {
      final sizeBytes = await File(savedPath).length().catchError((_) => 0);
      await _ref
          .read(downloadHistoryProvider.notifier)
          .addCompleted(
            music: music,
            quality: quality,
            savedPath: savedPath,
            sizeBytes: sizeBytes > 0 ? sizeBytes : null,
          );
    } catch (e) {
      log('history complete record FAIL: $e');
    }
  }

  Future<void> _recordFailed(
    MusicInfo music,
    Quality quality,
    String message,
    void Function(String) log,
  ) async {
    try {
      await _ref
          .read(downloadHistoryProvider.notifier)
          .addFailed(music: music, quality: quality, message: message);
    } catch (e) {
      log('history failed record FAIL: $e');
    }
  }

  Future<void> _attachDownload(
    MusicInfo music,
    Quality quality,
    String savedPath,
    void Function(String) log,
  ) async {
    try {
      final attached = await _ref
          .read(localPlaylistsProvider.notifier)
          .attachDownload(music: music, quality: quality, localPath: savedPath);
      if (attached > 0) {
        log('playlist path attached to $attached track(s)');
      }
    } catch (e) {
      log('playlist path attach FAIL: $e');
    }
  }

  String _messageFor(Object error) {
    if (error is DioException) return describeDioError(error);
    return error.toString();
  }
}

class _DownloadedAudio {
  const _DownloadedAudio({
    required this.tmpPath,
    required this.fileName,
    required this.quality,
  });

  final String tmpPath;
  final String fileName;
  final Quality quality;
}

final downloadServiceProvider = Provider<DownloadService>(
  (ref) => DownloadService(ref),
);

class DownloadPausedException implements Exception {
  const DownloadPausedException();
  @override
  String toString() => '下载已暂停';
}

Map<String, dynamic> _embedJson(EmbedRequest value) => {
  'cover': value.embedCover, 'lyric': value.embedLyric,
  'translated': value.embedTranslatedLyric, 'roman': value.embedRomanLyric,
  'format': value.lyricFormat.code,
};

EmbedRequest _embedFromJson(Map<String, dynamic> value) => EmbedRequest(
  embedCover: value['cover'] as bool? ?? true,
  embedLyric: value['lyric'] as bool? ?? true,
  embedTranslatedLyric: value['translated'] as bool? ?? true,
  embedRomanLyric: value['roman'] as bool? ?? true,
  lyricFormat: EmbeddedLyricFormat.values.firstWhere(
    (format) => format.code == value['format'], orElse: () => EmbeddedLyricFormat.automatic),
);
