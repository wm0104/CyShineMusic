import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/app_info.dart';
import '../../core/api/dio_factory.dart';
import '../../core/models/enums.dart';
import '../../core/music_sources/music_source_controller.dart';
import '../../core/services/permission_service.dart';
import '../../core/storage/settings_store.dart';
import '../../core/sync/webdav_sync_controller.dart';
import '../../core/ui/app_toast.dart';
import '../../core/ui/car_display_layout.dart';
import '../../theme/dynamic_color_status.dart';
import '../discovery/discovery_controller.dart';
import '../equalizer/equalizer_store.dart';
import '../player/sleep_timer_controller.dart';
import '../player/widgets/player_sleep_timer_sheet.dart';
import '../shell/shell_toolbar_visibility.dart';
import '../shell/shell_bottom_area.dart';
import '../songs/local_song_scan_cache.dart';
import '../update/app_update_prompt.dart';
import '../update/app_update_section.dart';
import 'widgets/color_picker_sheet.dart';
import 'widgets/color_style_row.dart';
import 'widgets/custom_theme_sheet.dart';
import 'widgets/discovery_source_order_sheet.dart';
import 'widgets/player_interface_settings_sheet.dart';
import 'widgets/settings_action.dart';
import 'widgets/playlist_backup_actions.dart';
import 'widgets/settings_menu.dart';
import 'widgets/settings_number_control.dart';
import 'widgets/storage_folder_picker_sheet.dart';
import 'widgets/theme_mode_row.dart';
import 'widgets/theme_seed_row.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final sourceState = ref.watch(musicSourceControllerProvider);
    final equalizer = ref.watch(equalizerProvider);
    final versionLabel = ref.watch(appVersionLabelProvider);
    final baseTheme = Theme.of(context);
    final scheme = baseTheme.colorScheme;

    return Theme(
      data: baseTheme.copyWith(scaffoldBackgroundColor: scheme.surface),
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: CustomScrollView(
          key: const PageStorageKey('settings-scroll'),
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                28,
                2,
                28,
                ShellBottomArea.contentPadding(context, 118),
              ),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: CarDisplayLayout.contentConstraints(
                      context,
                      maxWidth: 640,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SettingsCard(
                          title: '音源与搜索',
                          children: [
                            SettingsAction(
                              icon: Symbols.audio_file,
                              title: '音源管理',
                              subtitle: sourceState.when(
                                data: (value) => value.primary == null
                                    ? '未启用音源'
                                    : '已启用 ${value.enabledIds.length} 个 · '
                                          '首选：${value.primary!.name}',
                                loading: () => '正在加载音源',
                                error: (_, _) => '音源状态读取失败',
                              ),
                              trailing: Symbols.chevron_right,
                              onTap: () => context.go('/settings/sources'),
                            ),
                            SettingsSwitchAction(
                              key: const ValueKey('source-file-picker-setting'),
                              icon: Icons.snippet_folder_outlined,
                              title: '音源内置文件选择器',
                              subtitle: '系统无法选择 JS 时开启，支持内部存储和 U 盘',
                              value: settings.useBuiltInSourceFilePicker,
                              onChanged: (value) => ref
                                  .read(settingsProvider.notifier)
                                  .setUseBuiltInSourceFilePicker(value),
                            ),
                            SettingsMenuAction(
                              key: const ValueKey('search-source-menu'),
                              menuId: 'search-source-menu',
                              icon: Icons.manage_search_rounded,
                              title: '搜索源管理',
                              subtitle:
                                  '已启用 ${settings.enabledSearchSources.map((source) => source.label).join('、')}',
                              multiSelect: true,
                              options: [
                                for (final source in kManageableSearchSources)
                                  SettingsMenuOption(
                                    id: source.code,
                                    label: source.label,
                                    selected: settings.enabledSearchSources
                                        .contains(source),
                                    enabled:
                                        settings.enabledSearchSources.length !=
                                            1 ||
                                        !settings.enabledSearchSources.contains(
                                          source,
                                        ),
                                    onSelected: () => _setSearchSourceEnabled(
                                      context,
                                      ref,
                                      source,
                                      !settings.enabledSearchSources.contains(
                                        source,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            SettingsAction(
                              key: const ValueKey('discovery-source-order'),
                              icon: Icons.explore_outlined,
                              title: '发现页平台顺序',
                              subtitle: settings.discoverySourceOrder
                                  .map((source) => source.label)
                                  .join('、'),
                              trailing: Icons.chevron_right_rounded,
                              onTap: () => unawaited(
                                _showDiscoverySourceOrderSheet(context, ref),
                              ),
                            ),
                            SettingsMenuAction(
                              key: const ValueKey('network-adapter-menu'),
                              menuId: 'network-adapter-menu',
                              icon: Icons.cable_rounded,
                              title: '网络适配器',
                              subtitle:
                                  '${settings.networkAdapterMode.label} · '
                                  '${settings.networkAdapterMode.description}',
                              options: [
                                for (final mode in NetworkAdapterMode.values)
                                  SettingsMenuOption(
                                    id: mode.code,
                                    label: mode.label,
                                    selected:
                                        mode == settings.networkAdapterMode,
                                    onSelected: () =>
                                        _setNetworkAdapter(context, ref, mode),
                                  ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 30),
                        SettingsCard(
                          title: '播放',
                          children: [
                            SettingsMenuAction(
                              key: const ValueKey('online-quality-menu'),
                              menuId: 'online-quality-menu',
                              icon: Icons.high_quality_rounded,
                              title: '在线播放音质',
                              subtitle:
                                  '${settings.onlinePlaybackQuality.label} · '
                                  '${settings.onlinePlaybackQuality.description}',
                              options: [
                                for (final quality
                                    in OnlinePlaybackQuality.values)
                                  SettingsMenuOption(
                                    id: quality.code,
                                    label: quality.label,
                                    selected:
                                        quality ==
                                        settings.onlinePlaybackQuality,
                                    onSelected: () => _setOnlinePlaybackQuality(
                                      context,
                                      ref,
                                      quality,
                                    ),
                                  ),
                              ],
                            ),
                            SettingsAction(
                              key: const ValueKey('equalizer-setting'),
                              icon: Icons.graphic_eq_rounded,
                              title: '均衡器',
                              subtitle: equalizer.summary,
                              trailing: Symbols.chevron_right,
                              onTap: () => context.go('/settings/equalizer'),
                            ),
                            SettingsAction(
                              icon: Icons.multitrack_audio_rounded,
                              title: '淡入/淡出',
                              subtitle: settings.crossfadeSeconds == 0
                                  ? '已关闭 · 0 秒'
                                  : '${settings.crossfadeSeconds} 秒 · 歌曲切换时交叠播放',
                              trailing: Symbols.chevron_right,
                              onTap: () => _openSheet<void>(
                                context,
                                ref,
                                '淡入/淡出',
                                _crossfadeSettings,
                              ),
                            ),
                            Consumer(
                              builder: (context, ref, _) {
                                final remaining = ref.watch(sleepTimerProvider);
                                return SettingsAction(
                                  key: const ValueKey('sleep-timer-setting'),
                                  icon: Icons.timer_outlined,
                                  title: '定时关闭音乐',
                                  subtitle: remaining == null
                                      ? '未开启 · 到时自动暂停播放'
                                      : '剩余 ${formatSleepTimerRemaining(remaining)} 后暂停播放',
                                  trailing: Symbols.chevron_right,
                                  onTap: () =>
                                      showPlayerSleepTimerSheet(context, ref),
                                );
                              },
                            ),
                            SettingsSwitchAction(
                              key: const ValueKey(
                                'auto-play-on-startup-setting',
                              ),
                              icon: Icons.play_circle_outline_rounded,
                              title: '启动后自动播放',
                              subtitle: settings.autoPlayOnStartup
                                  ? '打开 APP 后自动恢复上次播放并继续播放'
                                  : '打开 APP 后仅恢复上次播放状态，不自动播放',
                              value: settings.autoPlayOnStartup,
                              onChanged: (value) => ref
                                  .read(settingsProvider.notifier)
                                  .setAutoPlayOnStartup(value),
                            ),
                            const SizedBox(height: 4),
                            SettingsSwitchAction(
                              key: const ValueKey(
                                'allow-mix-with-others-setting',
                              ),
                              icon: Icons.multitrack_audio_rounded,
                              title: '允许与其他 APP 共同播放',
                              subtitle: settings.allowMixWithOthers
                                  ? '不会抢占其他 APP 的音频，可同时播放'
                                  : '播放时保持独占音频',
                              value: settings.allowMixWithOthers,
                              onChanged: (value) => ref
                                  .read(settingsProvider.notifier)
                                  .setAllowMixWithOthers(value),
                            ),
                            SettingsAction(
                              icon: Icons.bluetooth_audio_rounded,
                              title: '蓝牙歌词',
                              subtitle: '显示蓝牙歌词、显示完整蓝牙歌词',
                              trailing: Symbols.chevron_right,
                              onTap: () => _openSheet<void>(
                                context,
                                ref,
                                '蓝牙歌词',
                                _bluetoothSettings,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 30),
                        SettingsCard(
                          title: '下载与本地音乐',
                          children: [
                            SettingsMenuAction(
                              key: const ValueKey(
                                'batch-download-quality-menu',
                              ),
                              menuId: 'batch-download-quality-menu',
                              icon: Icons.download_for_offline_rounded,
                              title: '批量下载音质',
                              subtitle:
                                  '${settings.batchDownloadQuality.label} · '
                                  '${settings.batchDownloadQuality.description}',
                              options: [
                                for (final quality
                                    in OnlinePlaybackQuality.values)
                                  SettingsMenuOption(
                                    id: quality.code,
                                    label: quality.label,
                                    selected:
                                        quality ==
                                        settings.batchDownloadQuality,
                                    onSelected: () => _setBatchDownloadQuality(
                                      context,
                                      ref,
                                      quality,
                                    ),
                                  ),
                              ],
                            ),
                            SettingsAction(
                              icon: Icons.folder_outlined,
                              title: '下载位置',
                              subtitle: settings.downloadDir,
                              trailing: Symbols.chevron_right,
                              onTap: () => _openDirectorySettings(
                                context,
                                ref,
                                download: true,
                              ),
                            ),
                            SettingsAction(
                              icon: Icons.library_music_outlined,
                              title: '扫描文件夹',
                              subtitle: settings.localMusicDir,
                              trailing: Symbols.chevron_right,
                              onTap: () => _openDirectorySettings(
                                context,
                                ref,
                                download: false,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 30),
                        SettingsCard(
                          title: '外观与界面',
                          children: [
                            SettingsAction(
                              icon: Icons.palette_outlined,
                              title: '主题与配色',
                              subtitle: '跟随系统、主题颜色与配色风格',
                              trailing: Symbols.chevron_right,
                              onTap: () => _openSheet<void>(
                                context,
                                ref,
                                '主题与配色',
                                _themeSettings,
                              ),
                            ),
                            SettingsAction(
                              key: const ValueKey('player-interface-setting'),
                              icon: Icons.display_settings_rounded,
                              title: '播放界面设置',
                              subtitle: '封面、歌词与动态流光',
                              trailing: Icons.chevron_right_rounded,
                              onTap: () =>
                                  _configurePlayerInterface(context, ref),
                            ),
                            SettingsMenuAction(
                              key: const ValueKey('navigation-mode-menu'),
                              menuId: 'navigation-mode-menu',
                              icon: Icons.view_day_outlined,
                              title: '导航模式',
                              subtitle:
                                  '${settings.navigationMode.label} · '
                                  '${settings.navigationMode.description}',
                              options: [
                                for (final mode in AppNavigationMode.values)
                                  SettingsMenuOption(
                                    id: mode.code,
                                    label: mode.label,
                                    selected: mode == settings.navigationMode,
                                    onSelected: () =>
                                        _setNavigationMode(context, ref, mode),
                                  ),
                              ],
                            ),
                            SettingsAction(
                              icon: Icons.directions_car_filled_rounded,
                              title: '车机与平板',
                              subtitle: '车机/Pad 模式与车机显示适配',
                              trailing: Symbols.chevron_right,
                              onTap: () => _openSheet<void>(
                                context,
                                ref,
                                '车机与平板',
                                _carSettings,
                              ),
                            ),
                            SettingsSwitchAction(
                              key: const ValueKey(
                                'skip-startup-screen-setting',
                              ),
                              icon: Icons.skip_next_rounded,
                              title: '跳过启动页',
                              subtitle: '下次启动生效，开启后直接进入主页',
                              value: settings.skipStartupScreen,
                              onChanged: (value) => ref
                                  .read(settingsProvider.notifier)
                                  .setSkipStartupScreen(value),
                            ),
                          ],
                        ),
                        const SizedBox(height: 30),
                        SettingsCard(
                          title: '关于',
                          children: [
                            if (Platform.isIOS)
                              const AppUpdateSection()
                            else
                              SettingsAction(
                                key: const ValueKey('check-update-setting'),
                                icon: Icons.system_update_alt_rounded,
                                title: '检查更新',
                                subtitle: '当前版本：$versionLabel',
                                trailing: Symbols.chevron_right,
                                onTap: () => unawaited(
                                  checkForAppUpdate(
                                    context,
                                    ref,
                                    showFeedback: true,
                                  ),
                                ),
                              ),
                            SettingsAction(
                              key: const ValueKey('backup-and-restore-setting'),
                              icon: Icons.cloud_upload_outlined,
                              title: '备份与恢复',
                              subtitle: '本地备份、云端恢复与 WebDAV',
                              trailing: Symbols.chevron_right,
                              onTap: () => _openBackupSettings(context, ref),
                            ),
                            DebugModeRow(
                              value: settings.debugMode,
                              onChanged: (value) => ref
                                  .read(settingsProvider.notifier)
                                  .setDebugMode(value),
                            ),
                            if (settings.debugMode) ...[
                              const SizedBox(height: 12),
                              SettingsAction(
                                icon: Icons.terminal_rounded,
                                title: '日志控制台',
                                subtitle: '实时查看播放、缓冲、音源和网络错误',
                                trailing: Symbols.chevron_right,
                                onTap: () => context.go('/debug'),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 72),
                        Text(
                          versionLabel,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: scheme.outline,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<T?> _openSheet<T>(
    BuildContext context,
    WidgetRef ref,
    String title,
    List<Widget> Function(BuildContext, WidgetRef) content,
  ) async {
    final toolbar = ref.read(shellToolbarVisibleProvider.notifier);
    final wasVisible = toolbar.state;
    toolbar.state = false;
    try {
      return await showModalBottomSheet<T>(
        context: context,
        useRootNavigator: true,
        useSafeArea: true,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.8,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Consumer(
                  builder: (context, ref, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ...content(context, ref),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('完成'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    } finally {
      if (toolbar.mounted) toolbar.state = wasVisible;
    }
  }

  List<Widget> _crossfadeSettings(BuildContext context, WidgetRef ref) {
    final seconds = ref.watch(
      settingsProvider.select((s) => s.crossfadeSeconds),
    );
    return [
      Text(
        '切换歌曲时，上一首渐弱，下一首同时渐强。',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 24),
      SettingsNumberControl(
        icon: Icons.multitrack_audio_rounded,
        label: '过渡时长（秒）',
        value: seconds.toDouble(),
        min: 0,
        max: kMaxCrossfadeSeconds.toDouble(),
        step: 1,
        onChanged: (value) => ref
            .read(settingsProvider.notifier)
            .setCrossfadeSeconds(value.round()),
      ),
      const SizedBox(height: 12),
      Text(seconds == 0 ? '0 秒 · 已关闭淡入/淡出' : '上一首的最后 $seconds 秒渐弱，同时下一首渐强。'),
    ];
  }

  List<Widget> _bluetoothSettings(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return [
      SettingsSwitchAction(
        key: const ValueKey('bluetooth-lyric-setting'),
        icon: Icons.bluetooth_audio_rounded,
        title: '显示蓝牙歌词',
        subtitle: '将当前歌词行作为媒体标题发送到车机或蓝牙设备',
        value: settings.bluetoothLyricEnabled,
        onChanged: (value) => _setBluetoothLyricEnabled(context, ref, value),
      ),
      SettingsSwitchAction(
        key: const ValueKey('bluetooth-full-lyric-setting'),
        icon: Icons.lyrics_rounded,
        title: '显示完整蓝牙歌词',
        subtitle: '写入完整 LRC，需接收设备支持',
        value: settings.bluetoothFullLyricEnabled,
        onChanged: (value) =>
            _setBluetoothFullLyricEnabled(context, ref, value),
      ),
    ];
  }

  List<Widget> _carSettings(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return [
      SettingsSwitchAction(
        key: const ValueKey('car-pad-mode-setting'),
        icon: Icons.directions_car_filled_rounded,
        title: '车机/Pad 模式',
        subtitle: settings.carPadModeEnabled ? '播放页使用左右分栏宽屏布局' : '关闭，播放页保持手机布局',
        value: settings.carPadModeEnabled,
        onChanged: (value) =>
            ref.read(settingsProvider.notifier).setCarPadModeEnabled(value),
      ),
      const SizedBox(height: 4),
      SettingsSwitchAction(
        key: const ValueKey('car-display-setting'),
        icon: Icons.display_settings_rounded,
        title: '车机显示适配',
        subtitle: settings.carDisplayEnabled
            ? '已开启：全局放大、内容铺开、横屏分栏，仅此设备生效'
            : '适合车机上文字按钮偏小、页面两侧留白过多的情况',
        value: settings.carDisplayEnabled,
        onChanged: (value) =>
            ref.read(settingsProvider.notifier).setCarDisplayEnabled(value),
      ),
      if (settings.carDisplayEnabled)
        SettingsMenuAction(
          menuId: 'car-display-size-menu',
          icon: Icons.format_size_rounded,
          title: '车机界面大小',
          subtitle: switch (settings.carDisplaySize) {
            < 1 => '紧凑 · 显示更多内容',
            > 1.1 => '更大 · 更易看清和点击',
            _ => '标准 · 按当前窗口调整',
          },
          options: [
            for (final option in {0.85: '紧凑', 1.0: '标准', 1.25: '更大'}.entries)
              SettingsMenuOption(
                id: option.key.toString(),
                label: option.value,
                selected: settings.carDisplaySize == option.key,
                onSelected: () => ref
                    .read(settingsProvider.notifier)
                    .setCarDisplaySize(option.key),
              ),
          ],
        ),
    ];
  }

  List<Widget> _themeSettings(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final dynamicColor = ref.watch(dynamicColorStatusProvider);
    Widget themePresets = Column(
      children: [
        ThemeSeedRow(
          value: settings.themeSeed,
          onPick: (color) =>
              ref.read(settingsProvider.notifier).setThemeSeed(color),
          onCustomize: () => _pickThemeSeed(context, ref),
        ),
        const SizedBox(height: 18),
        ColorStyleRow(
          value: settings.colorStyle,
          seed: settings.themeSeed,
          enabled:
              settings.customTheme.enabled ||
              !(settings.useDynamicColor && dynamicColor.available),
          onPick: (style) =>
              ref.read(settingsProvider.notifier).setColorStyle(style),
        ),
        const SizedBox(height: 18),
        DynamicColorRow(
          value: settings.useDynamicColor,
          available: dynamicColor.available,
          onChanged: (value) =>
              ref.read(settingsProvider.notifier).setUseDynamicColor(value),
        ),
      ],
    );
    if (settings.customTheme.enabled) {
      themePresets = Semantics(
        enabled: false,
        child: ExcludeFocus(child: IgnorePointer(child: themePresets)),
      );
    }
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ThemeModeRow(value: settings.themeMode),
      ),
      const SizedBox(height: 18),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: themePresets,
      ),
      SettingsAction(
        icon: Icons.palette_outlined,
        title: '自定义主题',
        subtitle: settings.customTheme.enabled
            ? '已启用 · 分别设置浅色和深色配色'
            : '独立设置强调色、背景、卡片和文字',
        trailing: Icons.chevron_right,
        onTap: () => _customizeTheme(context, ref),
      ),
      SettingsSwitchAction(
        icon: Icons.auto_awesome_outlined,
        title: '歌单详情动态配色',
        subtitle: settings.playlistArtworkColorsEnabled
            ? '根据歌单封面配色，会覆盖全局主题'
            : '使用全局主题，不根据封面改变颜色',
        value: settings.playlistArtworkColorsEnabled,
        onChanged: (value) => ref
            .read(settingsProvider.notifier)
            .setPlaylistArtworkColorsEnabled(value),
      ),
    ];
  }

  Future<void> _openDirectorySettings(
    BuildContext context,
    WidgetRef ref, {
    required bool download,
  }) => _openSheet<void>(context, ref, download ? '下载位置' : '扫描文件夹', (
    context,
    ref,
  ) {
    final settings = ref.watch(settingsProvider);
    return [
      SettingsAction(
        icon: download ? Icons.folder_outlined : Icons.library_music_outlined,
        title: '当前文件夹',
        subtitle: download ? settings.downloadDir : settings.localMusicDir,
        trailing: Symbols.chevron_right,
        onTap: () => download
            ? _pickDownloadDir(context, ref)
            : _pickLocalMusicDir(context, ref),
      ),
      Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          FilledButton.tonalIcon(
            onPressed: () => download
                ? _resetDownloadDir(context, ref)
                : _resetLocalMusicDir(context, ref),
            icon: Icon(
              download ? Icons.restart_alt : Icons.sync_rounded,
              size: 18,
            ),
            label: Text(download ? '恢复默认' : '恢复为下载位置'),
          ),
          FilledButton.tonalIcon(
            onPressed: () => download
                ? _browseDownloadDir(context, ref)
                : _browseLocalMusicDir(context, ref),
            icon: const Icon(Icons.storage_rounded, size: 18),
            label: const Text('浏览U盘'),
          ),
        ],
      ),
    ];
  });

  Future<void> _setBluetoothLyricEnabled(
    BuildContext context,
    WidgetRef ref,
    bool value,
  ) async {
    if (value) await _ensureBluetoothLyricNotice(context, ref);
    if (!context.mounted) return;
    await ref.read(settingsProvider.notifier).setBluetoothLyricEnabled(value);
  }

  Future<void> _setBluetoothFullLyricEnabled(
    BuildContext context,
    WidgetRef ref,
    bool value,
  ) async {
    if (value) await _ensureBluetoothLyricNotice(context, ref);
    if (!context.mounted) return;
    await ref
        .read(settingsProvider.notifier)
        .setBluetoothFullLyricEnabled(value);
  }

  Future<void> _ensureBluetoothLyricNotice(
    BuildContext context,
    WidgetRef ref,
  ) async {
    if (ref.read(settingsProvider).bluetoothLyricNoticeSeen) return;
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.directions_car_filled_rounded),
        title: const Text('蓝牙歌词提示'),
        content: const Text(
          '蓝牙歌词通过媒体信息兼容发送，不同车机或蓝牙设备的支持情况可能不同。'
          '\n\n驾车时请勿操作手机，注意道路安全。',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
    await ref.read(settingsProvider.notifier).markBluetoothLyricNoticeSeen();
  }

  Future<void> _resetDownloadDir(BuildContext context, WidgetRef ref) async {
    await ref
        .read(settingsProvider.notifier)
        .setDownloadDir(kDefaultDownloadDir);
    if (!context.mounted) return;
    showAppToast(context, '已恢复默认下载位置', type: AppToastType.success);
  }

  Future<void> _resetLocalMusicDir(BuildContext context, WidgetRef ref) async {
    final downloadDir = ref.read(settingsProvider).downloadDir;
    await ref.read(settingsProvider.notifier).setLocalMusicDir(downloadDir);
    unawaited(
      ref.read(localSongScanCacheProvider).refresh(directory: downloadDir),
    );
    if (!context.mounted) return;
    showAppToast(context, '已恢复为下载位置', type: AppToastType.success);
  }

  Future<void> _pickDownloadDir(BuildContext context, WidgetRef ref) async {
    final ok = await PermissionService.ensureExternalStorageWrite();
    if (!context.mounted) return;
    if (!ok) {
      showAppToast(context, '未授予存储权限，将无法写入公共目录', type: AppToastType.warning);
      return;
    }

    String? path;
    try {
      path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择下载目录',
        lockParentWindow: true,
      );
    } on PlatformException catch (_) {
      if (!context.mounted) return;
      path = await _showStorageFolderPicker(
        context,
        ref,
        title: '选择下载目录',
        initialPath: ref.read(settingsProvider).downloadDir,
      );
    }
    if (Platform.isAndroid &&
        path != null &&
        path.isNotEmpty &&
        (path == Platform.pathSeparator || !await Directory(path).exists())) {
      if (!context.mounted) return;
      path = await _showStorageFolderPicker(
        context,
        ref,
        title: '选择下载目录',
        initialPath: ref.read(settingsProvider).downloadDir,
      );
    }
    if (!context.mounted) return;
    if (path == null || path.isEmpty) return;

    if (!await _validateWritableDirectory(context, path)) return;
    await ref.read(settingsProvider.notifier).setDownloadDir(path);
    if (!context.mounted) return;
    showAppToast(context, '下载目录已切换到 $path', type: AppToastType.success);
  }

  Future<void> _browseDownloadDir(BuildContext context, WidgetRef ref) async {
    final ok = await PermissionService.ensureExternalStorageWrite();
    if (!context.mounted) return;
    if (!ok) {
      showAppToast(context, '未授予存储权限，将无法写入公共目录', type: AppToastType.warning);
      return;
    }

    final path = await _showStorageFolderPicker(
      context,
      ref,
      title: '选择下载目录',
      initialPath: ref.read(settingsProvider).downloadDir,
    );
    if (!context.mounted || path == null || path.isEmpty) return;

    if (!await _validateWritableDirectory(context, path)) return;
    await ref.read(settingsProvider.notifier).setDownloadDir(path);
    if (!context.mounted) return;
    showAppToast(context, '下载目录已切换到 $path', type: AppToastType.success);
  }

  Future<void> _pickLocalMusicDir(BuildContext context, WidgetRef ref) async {
    final ok = await PermissionService.ensureExternalStorageRead();
    if (!context.mounted) return;
    if (!ok) {
      showAppToast(context, '未授予存储权限，将无法读取本地音乐', type: AppToastType.warning);
      return;
    }

    String? path;
    try {
      path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择扫描文件夹',
        lockParentWindow: true,
      );
    } on PlatformException catch (_) {
      if (!context.mounted) return;
      path = await _showStorageFolderPicker(
        context,
        ref,
        title: '选择扫描文件夹',
        initialPath: ref.read(settingsProvider).localMusicDir,
      );
    }
    if (Platform.isAndroid &&
        path != null &&
        path.isNotEmpty &&
        (path == Platform.pathSeparator || !await Directory(path).exists())) {
      if (!context.mounted) return;
      path = await _showStorageFolderPicker(
        context,
        ref,
        title: '选择扫描文件夹',
        initialPath: ref.read(settingsProvider).localMusicDir,
      );
    }
    if (!context.mounted || path == null || path.isEmpty) return;

    await _applyLocalMusicDir(context, ref, path);
  }

  Future<void> _browseLocalMusicDir(BuildContext context, WidgetRef ref) async {
    final ok = await PermissionService.ensureExternalStorageRead();
    if (!context.mounted) return;
    if (!ok) {
      showAppToast(context, '未授予存储权限，将无法读取本地音乐', type: AppToastType.warning);
      return;
    }

    final path = await _showStorageFolderPicker(
      context,
      ref,
      title: '从U盘选择扫描文件夹',
      initialPath: ref.read(settingsProvider).localMusicDir,
    );
    if (!context.mounted || path == null || path.isEmpty) return;

    await _applyLocalMusicDir(context, ref, path);
  }

  Future<void> _applyLocalMusicDir(
    BuildContext context,
    WidgetRef ref,
    String path,
  ) async {
    if (!await _validateReadableDirectory(context, path)) return;
    await ref.read(settingsProvider.notifier).setLocalMusicDir(path);
    unawaited(ref.read(localSongScanCacheProvider).refresh(directory: path));
    if (!context.mounted) return;
    showAppToast(context, '本地音乐扫描文件夹已切换到 $path', type: AppToastType.success);
  }

  Future<String?> _showStorageFolderPicker(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String initialPath,
  }) async {
    FocusManager.instance.primaryFocus?.unfocus();
    var browsePath = initialPath;
    while (!await Directory(browsePath).exists()) {
      final parent = Directory(browsePath).parent.path;
      if (parent == browsePath) {
        browsePath = '';
        break;
      }
      browsePath = parent;
    }
    if (!context.mounted) return null;
    final toolbar = ref.read(shellToolbarVisibleProvider.notifier);
    final wasToolbarVisible = ref.read(shellToolbarVisibleProvider);
    toolbar.state = false;
    try {
      return await showStorageFolderPickerSheet(
        context,
        title: title,
        initialPath: browsePath.isEmpty ? null : browsePath,
      );
    } finally {
      if (toolbar.mounted) toolbar.state = wasToolbarVisible;
    }
  }

  Future<void> _showDiscoverySourceOrderSheet(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final toolbar = ref.read(shellToolbarVisibleProvider.notifier);
    final wasToolbarVisible = ref.read(shellToolbarVisibleProvider);
    toolbar.state = false;
    try {
      await showDiscoverySourceOrderSheet(
        context,
        order: ref.read(settingsProvider).discoverySourceOrder,
        onChanged: (order) async {
          await ref
              .read(settingsProvider.notifier)
              .setDiscoverySourceOrder(order);
          ref.read(selectedDiscoverySourceProvider.notifier).state =
              order.first;
        },
      );
    } finally {
      if (toolbar.mounted) toolbar.state = wasToolbarVisible;
    }
  }

  Future<bool> _validateWritableDirectory(
    BuildContext context,
    String path,
  ) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) throw FileSystemException('目录不存在', path);
      final probe = File('${dir.path}${Platform.pathSeparator}.cyshine_probe');
      await probe.writeAsString('ok');
      await probe.delete();
    } catch (e) {
      if (!context.mounted) return false;
      showAppToast(context, '该目录不可写: $e', type: AppToastType.error);
      return false;
    }
    return true;
  }

  Future<bool> _validateReadableDirectory(
    BuildContext context,
    String path,
  ) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        throw FileSystemException('目录不存在', path);
      }
      await dir.list(followLinks: false).take(1).drain<void>();
    } catch (e) {
      if (!context.mounted) return false;
      showAppToast(context, '该目录不可读取: $e', type: AppToastType.error);
      return false;
    }
    return true;
  }

  Future<void> _setNetworkAdapter(
    BuildContext context,
    WidgetRef ref,
    NetworkAdapterMode selected,
  ) async {
    final current = ref.read(settingsProvider).networkAdapterMode;
    if (selected == current) return;
    await ref.read(settingsProvider.notifier).setNetworkAdapterMode(selected);
    if (!context.mounted) return;
    final type = selected == NetworkAdapterMode.native
        ? AppToastType.warning
        : AppToastType.success;
    showAppToast(context, '网络适配器已切换为 ${selected.label}', type: type);
  }

  Future<void> _setNavigationMode(
    BuildContext context,
    WidgetRef ref,
    AppNavigationMode selected,
  ) async {
    final current = ref.read(settingsProvider).navigationMode;
    if (selected == current) return;
    await ref.read(settingsProvider.notifier).setNavigationMode(selected);
    if (!context.mounted) return;
    showAppToast(
      context,
      '导航模式已切换为 ${selected.label}',
      type: AppToastType.success,
    );
  }

  Future<void> _setSearchSourceEnabled(
    BuildContext context,
    WidgetRef ref,
    MusicSource source,
    bool? enabled,
  ) async {
    if (enabled == null) return;
    final changed = await ref
        .read(settingsProvider.notifier)
        .setSearchSourceEnabled(source, enabled);
    if (!changed && context.mounted) {
      showAppToast(context, '至少保留一个搜索源', type: AppToastType.warning);
    }
  }

  Future<void> _setOnlinePlaybackQuality(
    BuildContext context,
    WidgetRef ref,
    OnlinePlaybackQuality quality,
  ) async {
    if (quality == ref.read(settingsProvider).onlinePlaybackQuality) return;
    await ref.read(settingsProvider.notifier).setOnlinePlaybackQuality(quality);
    if (!context.mounted) return;
    showAppToast(
      context,
      '在线播放音质已设为 ${quality.label}',
      type: AppToastType.success,
    );
  }

  Future<void> _setBatchDownloadQuality(
    BuildContext context,
    WidgetRef ref,
    OnlinePlaybackQuality quality,
  ) async {
    if (quality == ref.read(settingsProvider).batchDownloadQuality) return;
    await ref.read(settingsProvider.notifier).setBatchDownloadQuality(quality);
    if (!context.mounted) return;
    showAppToast(
      context,
      '批量下载音质已设为 ${quality.label}',
      type: AppToastType.success,
    );
  }

  Future<void> _configurePlayerInterface(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final toolbar = ref.read(shellToolbarVisibleProvider.notifier);
    final wasToolbarVisible = ref.read(shellToolbarVisibleProvider);
    toolbar.state = false;
    try {
      await showPlayerInterfaceSettingsSheet(context);
    } finally {
      if (toolbar.mounted) toolbar.state = wasToolbarVisible;
    }
  }

  Future<void> _openBackupSettings(BuildContext context, WidgetRef ref) async {
    final openWebDav = await _openSheet<bool>(
      context,
      ref,
      '备份与恢复',
      (context, ref) => [
        SettingsAction(
          key: const ValueKey('webdav-sync-setting'),
          icon: Icons.cloud_sync_outlined,
          title: 'WebDAV 同步',
          subtitle: _webDavSubtitle(ref.watch(webDavSyncControllerProvider)),
          trailing: Symbols.chevron_right,
          onTap: () => Navigator.of(context).pop(true),
        ),
        const PlaylistBackupActions(),
      ],
    );
    if (openWebDav == true && context.mounted) context.go('/settings/webdav');
  }

  Future<void> _customizeTheme(BuildContext context, WidgetRef ref) async {
    final settings = ref.read(settingsProvider);
    final toolbar = ref.read(shellToolbarVisibleProvider.notifier);
    final wasToolbarVisible = ref.read(shellToolbarVisibleProvider);
    toolbar.state = false;
    try {
      final selected = await showCustomThemeSheet(
        context,
        settings.customTheme,
        seed: settings.themeSeed,
        style: settings.colorStyle,
      );
      if (selected == null) return;
      await ref.read(settingsProvider.notifier).setCustomTheme(selected);
      if (!context.mounted) return;
      showAppToast(context, '自定义主题已更新', type: AppToastType.success);
    } finally {
      if (toolbar.mounted) toolbar.state = wasToolbarVisible;
    }
  }

  Future<void> _pickThemeSeed(BuildContext context, WidgetRef ref) async {
    final settings = ref.read(settingsProvider);
    final current = settings.themeSeed;
    final toolbar = ref.read(shellToolbarVisibleProvider.notifier);
    final wasToolbarVisible = ref.read(shellToolbarVisibleProvider);
    toolbar.state = false;
    Color? selected;
    try {
      selected = await showColorPickerSheet(
        context,
        current,
        style: settings.colorStyle,
      );
    } finally {
      if (toolbar.mounted) toolbar.state = wasToolbarVisible;
    }
    if (selected == null) return;
    await ref.read(settingsProvider.notifier).setThemeSeed(selected);
    if (!context.mounted) return;
    showAppToast(context, '主题颜色已更新', type: AppToastType.success);
  }
}

String _webDavSubtitle(AsyncValue<WebDavSyncState> value) {
  return value.when(
    loading: () => '正在读取同步配置',
    error: (_, _) => '同步配置读取失败',
    data: (sync) {
      if (!sync.config.isConfigured) return '未配置';
      if (sync.phase == WebDavSyncPhase.connecting) return '正在连接';
      if (sync.phase == WebDavSyncPhase.syncing) return '正在同步';
      if (sync.phase == WebDavSyncPhase.failure) {
        return sync.errorMessage ?? '最近同步失败';
      }
      final lastSyncedAt = sync.lastSyncedAt?.toLocal();
      if (lastSyncedAt == null) return '已连接，尚未同步';
      return '上次同步 ${_shortDateTime(lastSyncedAt)}';
    },
  );
}

String _shortDateTime(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.month}-${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
}
