import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sync/playlist_backup_service.dart';
import '../../../core/ui/app_toast.dart';
import 'settings_action.dart';

/// Reuses the settings rows and the app's modal list; no account setup here.
class PlaylistBackupActions extends ConsumerStatefulWidget {
  const PlaylistBackupActions({super.key});

  @override
  ConsumerState<PlaylistBackupActions> createState() => _PlaylistBackupActionsState();
}

class _PlaylistBackupActionsState extends ConsumerState<PlaylistBackupActions> {
  bool _busy = false;

  Future<void> _run(Future<String?> Function(PlaylistBackupService service) action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final message = await action(ref.read(playlistBackupServiceProvider));
      if (mounted && message != null) showAppToast(context, message, type: AppToastType.success);
    } catch (error) {
      if (mounted) showAppToast(context, '备份操作失败：$error', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(children: [
    SettingsAction(
      key: const ValueKey('playlist-backup-export'),
      icon: Icons.file_upload_outlined, title: '导出备份',
      subtitle: '保存歌单与 App 偏好，不包含音频',
      onTap: () => _run((service) async => await service.exportLocal() ? '备份已导出' : null),
    ),
    SettingsAction(
      key: const ValueKey('playlist-backup-import'),
      icon: Icons.file_download_outlined, title: '导入备份',
      subtitle: '歌单合并补缺，偏好随备份恢复',
      onTap: () => _run((service) async {
        final added = await service.importLocal();
        return added == null ? null : '备份已导入，补入 $added 项';
      }),
    ),
    SettingsAction(
      key: const ValueKey('playlist-backup-upload'),
      icon: Icons.cloud_upload_outlined, title: '上传到云端',
      subtitle: '使用已配置的 WebDAV，独立保存备份',
      onTap: () => _run((service) async { await service.uploadCloud(); return '备份已上传'; }),
    ),
    SettingsAction(
      key: const ValueKey('playlist-backup-restore'),
      icon: Icons.cloud_download_outlined, title: '从云端恢复',
      subtitle: _busy ? '正在处理备份' : '选择备份，合并补入缺少的内容',
      onTap: () => _run((service) async {
        final names = await service.listCloud();
        if (!context.mounted) return null;
        final selected = await showModalBottomSheet<String>(
          context: context, useRootNavigator: true,
          showDragHandle: true, isScrollControlled: true,
          builder: (sheetContext) => SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.58),
              child: names.isEmpty
                ? const Padding(padding: EdgeInsets.all(28), child: Text('暂无云端备份'))
                : ListView.builder(
                    key: const ValueKey('cloud-backup-list'),
                    shrinkWrap: true, itemCount: names.length,
                    itemBuilder: (_, index) => ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: Text(names[index], maxLines: 2),
                      onTap: () => Navigator.of(sheetContext).pop(names[index]),
                    ),
                  ),
            ),
          ),
        );
        if (selected == null || !context.mounted) return null;
        final added = await service.restoreCloud(selected);
        return '备份已恢复，补入 $added 项';
      }),
    ),
  ]);
}
