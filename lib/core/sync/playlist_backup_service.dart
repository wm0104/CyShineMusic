import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/playlists/playlist_store.dart';
import '../../features/playlists/playlist_backup.dart';
import '../../features/equalizer/equalizer_store.dart';
import '../storage/settings_store.dart';
import '../music_sources/music_source_controller.dart';
import '../storage/app_preferences_backup.dart';
import 'webdav_client.dart';
import 'webdav_config_store.dart';
import 'webdav_sync_controller.dart';

typedef PlaylistBackupFilePicker = Future<String?> Function();
typedef PlaylistBackupFileSaver = Future<bool> Function(String name, String text);

final playlistBackupFilePickerProvider = Provider<PlaylistBackupFilePicker>((ref) => () async {
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: '导入歌单备份', type: FileType.custom,
    allowedExtensions: const ['json'], allowMultiple: false, withData: true,
  );
  if (result == null) return null;
  final picked = result.files.single;
  final bytes = picked.bytes ?? (picked.path == null ? null : await File(picked.path!).readAsBytes());
  if (bytes == null) throw const FormatException('无法读取备份文件');
  return utf8.decode(bytes);
});

final playlistBackupFileSaverProvider = Provider<PlaylistBackupFileSaver>((ref) => (name, text) async {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return await const MethodChannel('cy_shine_music/audio_intent').invokeMethod<bool>(
      'savePlaylistBackup', {'name': name, 'text': text},
    ) ?? false;
  }
  final bytes = Uint8List.fromList(utf8.encode(text));
  final path = await FilePicker.platform.saveFile(
    dialogTitle: '导出歌单备份', fileName: name, type: FileType.custom,
    allowedExtensions: const ['json'], bytes: bytes,
  );
  if (path == null) return false;
  // Android saveFile writes the supplied bytes through the system picker.
  // Never guess a Documents path or write again outside the chosen location.
  if (!Platform.isIOS && !Platform.isAndroid) {
    await File(path).writeAsBytes(bytes, flush: true);
  }
  return true;
});

class PlaylistBackupService {
  PlaylistBackupService(this.ref);
  final Ref ref;

  String _name() {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '栖弦备份-${now.year}-$month-$day.json';
  }

  Future<String> _export() async => jsonEncode({
    ...jsonDecode(ref.read(localPlaylistsProvider.notifier).exportBackup()) as Map,
    'musicSources': await ref.read(musicSourceControllerProvider.notifier)
        .exportForSync(fileOrigin: '备份文件'),
    'preferences': {
      ...ref.read(settingsProvider.notifier).exportPreferencesForBackup(),
      'equalizer': ref.read(equalizerProvider).toJson(),
    },
  });

  Future<int> _restore(String text) async {
    // Validate the complete file before either store starts writing.
    decodePlaylistBackup(text);
    final document = jsonDecode(text) as Map;
    final preferences = document.containsKey('preferences')
        ? decodeAppPreferencesBackup(document['preferences']) : null;
    var sourceCount = 0;
    final added = await ref.read(localPlaylistsProvider.notifier).importBackup(text,
      beforeWrite: document.containsKey('musicSources') ? () async {
        sourceCount = await ref.read(musicSourceControllerProvider.notifier)
            .restoreMissingFromBackup(document['musicSources']);
      } : null,
    );
    // Playlist conflicts must never restore preferences first.
    if (preferences != null && preferences.isNotEmpty) {
      await ref.read(settingsProvider.notifier).applyValidatedPreferencesBackup(preferences);
      if (preferences.containsKey('equalizer')) {
        await ref.read(equalizerProvider.notifier).applyBackup(
          EqualizerSettings.fromJson(preferences['equalizer'] as Map<String, dynamic>),
        );
      }
    }
    return added + sourceCount;
  }

  Future<bool> exportLocal() async {
    final text = await _export();
    return ref.read(playlistBackupFileSaverProvider)(_name(), text);
  }

  Future<int?> importLocal() async {
    final text = await ref.read(playlistBackupFilePickerProvider)();
    if (text == null) return null;
    return _restore(text);
  }

  Future<WebDavClient> _client() async {
    final config = await ref.read(webDavConfigStoreProvider).load();
    if (!config.isConfigured) throw const WebDavException('请先配置已有 WebDAV 连接');
    return ref.read(webDavClientFactoryProvider)(config);
  }

  Future<void> uploadCloud() async {
    final text = await _export();
    final client = await _client();
    try {
      final stem = _name().replaceFirst('.json', '');
      final pattern = RegExp('^${RegExp.escape(stem)}(?:-([1-9][0-9]*))?${r'\.json$'}');
      var number = 1;
      var names = const <String>[];
      try {
        names = await client.listPlaylistBackups();
      } on WebDavException catch (error) {
        // Listing is optional on write-only servers or a missing collection.
        if (![403, 405, 409, 501].contains(error.statusCode)) rethrow;
      }
      for (final name in names) {
        final match = pattern.firstMatch(name);
        if (match == null) continue;
        final existing = int.tryParse(match.group(1) ?? '1');
        if (existing == null || existing >= 9999) {
          throw const WebDavException('同日备份数量已达上限');
        }
        if (existing >= number) number = existing + 1;
      }
      // A second device may claim the name after listing. Keep create-only PUTs
      // and retry a bounded number of fresh names instead of overwriting it.
      for (var attempt = 0; attempt < 10 && number <= 9999; attempt++, number++) {
        final name = number == 1 ? '$stem.json' : '$stem-$number.json';
        try {
          await client.uploadPlaylistBackup(name, text);
          return;
        } on WebDavException catch (error) {
          if (error.statusCode != 412) rethrow;
        }
      }
      throw const WebDavException('备份名称持续冲突或同日备份过多，请稍后重试');
    }
    finally { client.close(); }
  }

  Future<List<String>> listCloud() async {
    final client = await _client();
    try { return await client.listPlaylistBackups(); }
    finally { client.close(); }
  }

  Future<int> restoreCloud(String name) async {
    final client = await _client();
    final String text;
    try { text = await client.readPlaylistBackup(name); }
    finally { client.close(); }
    return _restore(text);
  }
}

final playlistBackupServiceProvider = Provider<PlaylistBackupService>(PlaylistBackupService.new);
