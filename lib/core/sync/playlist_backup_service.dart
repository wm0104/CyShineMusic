import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/playlists/playlist_store.dart';
import '../../features/playlists/playlist_backup.dart';
import '../../features/equalizer/equalizer_store.dart';
import '../storage/settings_store.dart';
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
  final bytes = Uint8List.fromList(utf8.encode(text));
  final path = await FilePicker.platform.saveFile(
    dialogTitle: '导出歌单备份', fileName: name, type: FileType.custom,
    allowedExtensions: const ['json'], bytes: bytes,
  );
  if (path == null) return false;
  // iOS/Android saveFile writes the supplied bytes through the system picker.
  // Never guess a Documents path or write again outside the chosen location.
  if (!Platform.isIOS && !Platform.isAndroid) {
    await File(path).writeAsBytes(bytes, flush: true);
  }
  return true;
});

class PlaylistBackupService {
  PlaylistBackupService(this.ref);
  final Ref ref;

  String _name() => 'playlist-backup-v1-${DateTime.now().microsecondsSinceEpoch}.json';

  String _export() => jsonEncode({
    ...jsonDecode(ref.read(localPlaylistsProvider.notifier).exportBackup()) as Map,
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
    final added = await ref.read(localPlaylistsProvider.notifier).importBackup(text);
    // Playlist conflicts must never restore preferences first.
    if (preferences != null && preferences.isNotEmpty) {
      await ref.read(settingsProvider.notifier).applyValidatedPreferencesBackup(preferences);
      if (preferences.containsKey('equalizer')) {
        await ref.read(equalizerProvider.notifier).applyBackup(
          EqualizerSettings.fromJson(preferences['equalizer'] as Map<String, dynamic>),
        );
      }
    }
    return added;
  }

  Future<bool> exportLocal() {
    final text = _export();
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
    final text = _export();
    final client = await _client();
    try { await client.uploadPlaylistBackup(_name(), text); }
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
