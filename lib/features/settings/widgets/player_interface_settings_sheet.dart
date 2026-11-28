import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/settings_store.dart';
import 'settings_action.dart';

Future<void> showPlayerInterfaceSettingsSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _PlayerInterfaceSettingsSheet(),
    );

class _PlayerInterfaceSettingsSheet extends ConsumerWidget {
  const _PlayerInterfaceSettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('播放界面设置', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              SettingsSwitchAction(
                key: const ValueKey('lyric-view-blur-disabled-setting'),
                icon: Icons.blur_off_rounded,
                title: '关闭歌词视图模糊',
                subtitle: settings.lyricViewBlurDisabled
                    ? '所有歌词清晰显示'
                    : '保留歌词远近模糊效果',
                value: settings.lyricViewBlurDisabled,
                onChanged: notifier.setLyricViewBlurDisabled,
              ),
              SettingsSwitchAction(
                key: const ValueKey('square-album-cover-setting'),
                icon: Icons.crop_square_rounded,
                title: '方形专辑封面',
                subtitle: settings.squareAlbumCoverEnabled
                    ? '使用静止的方形封面'
                    : '使用随播放旋转的圆形封面',
                value: settings.squareAlbumCoverEnabled,
                onChanged: notifier.setSquareAlbumCoverEnabled,
              ),
              SettingsSwitchAction(
                key: const ValueKey('flowing-light-setting'),
                icon: Icons.blur_on_rounded,
                title: '动态流光',
                subtitle: settings.flowingLightEnabled
                    ? '播放页背景取封面主色缓慢流动'
                    : '播放页使用静态封面模糊背景',
                value: settings.flowingLightEnabled,
                onChanged: notifier.setFlowingLightEnabled,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('完成'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
