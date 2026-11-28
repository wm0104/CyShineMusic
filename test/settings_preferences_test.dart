import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/api/dio_factory.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/player/lyric_parser.dart';
import 'package:cy_shine_music/features/player/widgets/karaoke_line_text.dart';
import 'package:cy_shine_music/features/player/widgets/lyric_line.dart';
import 'package:cy_shine_music/features/search/widgets/source_filter_chips.dart';
import 'package:cy_shine_music/features/settings/settings_page.dart';
import 'package:cy_shine_music/features/settings/widgets/settings_action.dart';
import 'package:cy_shine_music/features/settings/widgets/settings_style.dart';
import 'package:cy_shine_music/theme/app_theme.dart';
import 'package:cy_shine_music/theme/color_style.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'settings default to four search sources and highest quality preferences',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      addTearDown(container.dispose);

      final settings = container.read(settingsProvider);

      expect(settings.enabledSearchSources, kDefaultEnabledSearchSources);
      expect(settings.enabledSearchSources, isNot(contains(MusicSource.mg)));
      expect(settings.onlinePlaybackQuality, OnlinePlaybackQuality.highest);
      expect(settings.batchDownloadQuality, OnlinePlaybackQuality.highest);
      expect(settings.showMiniLyrics, isTrue);
      expect(settings.allowMixWithOthers, isFalse);
      expect(settings.autoPlayOnStartup, isFalse);
      expect(settings.bluetoothLyricEnabled, isFalse);
      expect(settings.bluetoothFullLyricEnabled, isFalse);
      expect(settings.bluetoothLyricNoticeSeen, isFalse);
      expect(settings.useNativeNavigation, isFalse);
      expect(settings.localMusicDir, settings.downloadDir);
      expect(settings.useBuiltInSourceFilePicker, isFalse);
    },
  );

  test('WebDAV appearance restore changes only appearance settings', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    await notifier.setOnlinePlaybackQuality(OnlinePlaybackQuality.lossless);

    await notifier.applyAppearanceFromSync({
      'themeMode': 'dark',
      'themeSeedArgb': 0xFF123456,
      'useDynamicColor': true,
    });

    final restored = container.read(settingsProvider);
    expect(restored.themeMode, ThemeMode.dark);
    expect(restored.themeSeed.toARGB32(), 0xFF123456);
    expect(restored.useDynamicColor, isTrue);
    expect(restored.onlinePlaybackQuality, OnlinePlaybackQuality.lossless);
  });

  test(
    'translation style migrates and persists independently of originals',
    () async {
      SharedPreferences.setMockInitialValues({
        'lyric_font_size': 48.0,
        'lyric_font_weight': 800.0,
      });
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      final notifier = container.read(settingsProvider.notifier);
      expect(container.read(settingsProvider).lyricTranslationFontSize, 21);
      expect(container.read(settingsProvider).lyricFontWeight, 800);
      expect(container.read(settingsProvider).lyricTranslationFontWeight, 700);

      final legacyAppearance = notifier.exportAppearanceForSync()
        ..remove('lyricTranslationFontSize')
        ..remove('lyricTranslationFontWeight');
      await notifier.applyAppearanceFromSync({
        ...legacyAppearance,
        'lyricFontSize': 40,
        'lyricFontWeight': 200,
      });
      container.dispose();

      final restored = _settingsContainer(prefs);
      final restoredNotifier = restored.read(settingsProvider.notifier);
      expect(restored.read(settingsProvider).lyricFontSize, 40);
      expect(restored.read(settingsProvider).lyricTranslationFontSize, 21);
      expect(restored.read(settingsProvider).lyricFontWeight, 200);
      expect(restored.read(settingsProvider).lyricTranslationFontWeight, 700);

      await restoredNotifier.applyAppearanceFromSync({
        ...legacyAppearance,
        'lyricTranslationFontSize': 30,
        'lyricTranslationFontWeight': 900,
      });
      await restoredNotifier.setLyricFontStyle(weight: 500, size: 32);
      expect(
        restoredNotifier.exportAppearanceForSync()['lyricTranslationFontSize'],
        30,
      );
      expect(
        restoredNotifier
            .exportAppearanceForSync()['lyricTranslationFontWeight'],
        900,
      );
      restored.dispose();

      final reloaded = _settingsContainer(prefs);
      addTearDown(reloaded.dispose);
      expect(reloaded.read(settingsProvider).lyricFontSize, 32);
      expect(reloaded.read(settingsProvider).lyricTranslationFontSize, 30);
      expect(reloaded.read(settingsProvider).lyricFontWeight, 500);
      expect(reloaded.read(settingsProvider).lyricTranslationFontWeight, 900);
    },
  );

  testWidgets(
    'full lyrics render translation style independently of original and roman',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      addTearDown(container.dispose);
      final blurSuppressed = ValueNotifier(false);
      final anchorMs = ValueNotifier(0);
      final playing = ValueNotifier(false);
      final buffering = ValueNotifier(false);
      addTearDown(blurSuppressed.dispose);
      addTearDown(anchorMs.dispose);
      addTearDown(playing.dispose);
      addTearDown(buffering.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: LyricLineTile(
                line: const KaraokeLyricLine(
                  startMs: 0,
                  endMs: 1000,
                  text: 'Original lyric',
                  translation: '中文译文',
                  roman: 'zhong wen yi wen',
                ),
                active: true,
                selected: false,
                distance: 0,
                blurSuppressed: blurSuppressed,
                showTranslation: true,
                anchorMs: anchorMs,
                playing: playing,
                buffering: buffering,
                onSelect: () {},
                onSeek: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      TextStyle renderedStyle(String lyric) {
        final track = find.byWidgetPredicate(
          (widget) =>
              widget is KaraokeLineText &&
              (widget.translation
                      ? widget.line.translation
                      : widget.line.text) ==
                  lyric,
        );
        final element = tester.element(
          track.evaluate().isEmpty ? find.text(lyric) : track,
        );
        return DefaultTextStyle.of(element).style;
      }

      await container
          .read(settingsProvider.notifier)
          .setLyricFontStyle(
            weight: 700,
            size: 32,
            translationWeight: 900,
            translationSize: 30,
          );
      await tester.pumpAndSettle();
      expect(renderedStyle('Original lyric').fontSize, 32);
      expect(renderedStyle('中文译文').fontSize, 30);
      expect(renderedStyle('zhong wen yi wen').fontSize, 12);
      expect(renderedStyle('Original lyric').fontWeight, FontWeight.w700);
      expect(renderedStyle('中文译文').fontWeight, FontWeight.w900);
      expect(renderedStyle('zhong wen yi wen').fontWeight, FontWeight.w600);
    },
  );

  test('color style persists and defaults to soft', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    expect(container.read(settingsProvider).colorStyle, AppColorStyle.soft);

    await container
        .read(settingsProvider.notifier)
        .setColorStyle(AppColorStyle.vivid);
    container.dispose();

    final restored = _settingsContainer(prefs);
    addTearDown(restored.dispose);
    expect(restored.read(settingsProvider).colorStyle, AppColorStyle.vivid);
  });

  test(
    'source file picker preference survives restart and appearance sync',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      await container
          .read(settingsProvider.notifier)
          .setUseBuiltInSourceFilePicker(true);
      await container.read(settingsProvider.notifier).applyAppearanceFromSync({
        'themeMode': 'dark',
        'themeSeedArgb': 0xFF123456,
        'useDynamicColor': false,
      });
      expect(
        container.read(settingsProvider).useBuiltInSourceFilePicker,
        isTrue,
      );
      container.dispose();

      final restored = _settingsContainer(prefs);
      addTearDown(restored.dispose);
      expect(
        restored.read(settingsProvider).useBuiltInSourceFilePicker,
        isTrue,
      );
      await restored
          .read(settingsProvider.notifier)
          .setUseBuiltInSourceFilePicker(false);
      expect(prefs.getBool('use_built_in_source_file_picker'), isFalse);
    },
  );

  test('appearance sync round-trips the color style', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);

    await notifier.setColorStyle(AppColorStyle.faithful);
    expect(
      notifier.exportAppearanceForSync()['colorStyle'],
      AppColorStyle.faithful.code,
    );

    await notifier.applyAppearanceFromSync({
      'themeMode': 'light',
      'themeSeedArgb': 0xFF00BCD4,
      'colorStyle': AppColorStyle.creative.code,
      'useDynamicColor': false,
    });
    expect(container.read(settingsProvider).colorStyle, AppColorStyle.creative);
  });

  test(
    'appearance payload without a color style keeps the local one',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.setColorStyle(AppColorStyle.vivid);

      // 旧版本写的备份没有 colorStyle 字段，不应被当成损坏数据。
      await notifier.applyAppearanceFromSync({
        'themeMode': 'dark',
        'themeSeedArgb': 0xFF123456,
        'useDynamicColor': false,
      });

      final restored = container.read(settingsProvider);
      expect(restored.colorStyle, AppColorStyle.vivid);
      expect(restored.themeMode, ThemeMode.dark);
    },
  );

  test('appearance sync rejects an unknown color style', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    addTearDown(container.dispose);

    expect(
      () => container.read(settingsProvider.notifier).applyAppearanceFromSync({
        'themeMode': 'dark',
        'themeSeedArgb': 0xFF123456,
        'colorStyle': 'not-a-style',
        'useDynamicColor': false,
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('native navigation is opt-in and persists across restarts', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    expect(AppSettings.fallback.useNativeNavigation, isFalse);
    expect(container.read(settingsProvider).useNativeNavigation, isFalse);
    await container
        .read(settingsProvider.notifier)
        .setUseNativeNavigation(true);
    container.dispose();

    final restored = _settingsContainer(prefs);
    expect(restored.read(settingsProvider).useNativeNavigation, isTrue);
    await restored
        .read(settingsProvider.notifier)
        .setUseNativeNavigation(false);
    restored.dispose();

    final disabled = _settingsContainer(prefs);
    addTearDown(disabled.dispose);
    expect(disabled.read(settingsProvider).useNativeNavigation, isFalse);
  });

  test(
    'navigation mode persists across restarts and supports dual capsule',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      expect(
        AppSettings.fallback.navigationMode,
        AppNavigationMode.singleCapsule,
      );
      expect(
        container.read(settingsProvider).navigationMode,
        AppNavigationMode.singleCapsule,
      );

      await container
          .read(settingsProvider.notifier)
          .setNavigationMode(AppNavigationMode.dualCapsule);
      container.dispose();

      final restored = _settingsContainer(prefs);
      expect(
        restored.read(settingsProvider).navigationMode,
        AppNavigationMode.dualCapsule,
      );
      expect(restored.read(settingsProvider).useNativeNavigation, isFalse);

      await restored
          .read(settingsProvider.notifier)
          .setNavigationMode(AppNavigationMode.native);
      restored.dispose();

      final nativeMode = _settingsContainer(prefs);
      addTearDown(nativeMode.dispose);
      expect(
        nativeMode.read(settingsProvider).navigationMode,
        AppNavigationMode.native,
      );
      expect(nativeMode.read(settingsProvider).useNativeNavigation, isTrue);
    },
  );

  test('player preferences persist', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    final notifier = container.read(settingsProvider.notifier);

    await notifier.setShowMiniLyrics(false);
    await notifier.setAllowMixWithOthers(true);
    await notifier.setBluetoothLyricEnabled(true);
    await notifier.setBluetoothFullLyricEnabled(true);
    await notifier.markBluetoothLyricNoticeSeen();
    container.dispose();

    final restored = _settingsContainer(prefs);
    addTearDown(restored.dispose);
    final settings = restored.read(settingsProvider);
    expect(settings.showMiniLyrics, isFalse);
    expect(settings.allowMixWithOthers, isTrue);
    expect(settings.bluetoothLyricEnabled, isTrue);
    expect(settings.bluetoothFullLyricEnabled, isTrue);
    expect(settings.bluetoothLyricNoticeSeen, isTrue);
  });

  test('auto-play-on-startup preference persists across restarts', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    final notifier = container.read(settingsProvider.notifier);

    await notifier.setAutoPlayOnStartup(true);
    container.dispose();

    final restored = _settingsContainer(prefs);
    addTearDown(restored.dispose);
    expect(restored.read(settingsProvider).autoPlayOnStartup, isTrue);
  });

  testWidgets('bluetooth lyric warning is shown only on first enable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    await _openSettingsRow(tester, '蓝牙歌词');
    final row = find.byKey(const ValueKey('bluetooth-lyric-setting'));
    final toggle = find.descendant(of: row, matching: find.byType(Switch));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('蓝牙歌词提示'), findsOneWidget);
    await tester.tap(find.text('我知道了'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).bluetoothLyricEnabled, isTrue);
    expect(container.read(settingsProvider).bluetoothLyricNoticeSeen, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('蓝牙歌词提示'), findsNothing);
    expect(container.read(settingsProvider).bluetoothLyricEnabled, isTrue);
  });

  testWidgets('switch settings align with actions and keep vertical spacing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SettingsAction(
                key: const ValueKey('reference-setting-action'),
                icon: Icons.search_rounded,
                title: '参考设置项',
                subtitle: '参考说明',
                onTap: () {},
              ),
              SettingsSwitchAction(
                key: const ValueKey('first-switch-setting'),
                icon: Icons.bluetooth_audio_rounded,
                title: '显示蓝牙歌词',
                subtitle: '蓝牙歌词说明',
                value: false,
                onChanged: (_) {},
              ),
              SettingsSwitchAction(
                key: const ValueKey('second-switch-setting'),
                icon: Icons.lyrics_rounded,
                title: '显示完整蓝牙歌词',
                subtitle: '完整歌词说明',
                value: false,
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
    );

    Finder bubbleWithin(Key key) => find.descendant(
      of: find.byKey(key),
      matching: find.byType(SettingsSymbolBubble),
    );

    final referenceRect = tester.getRect(
      bubbleWithin(const ValueKey('reference-setting-action')),
    );
    final firstRect = tester.getRect(
      bubbleWithin(const ValueKey('first-switch-setting')),
    );
    final secondRect = tester.getRect(
      bubbleWithin(const ValueKey('second-switch-setting')),
    );
    expect(firstRect.left, referenceRect.left);
    expect(secondRect.left, referenceRect.left);
    expect(secondRect.top - firstRect.bottom, greaterThanOrEqualTo(24));
    expect(tester.takeException(), isNull);
  });

  test('legacy resolver setting is removed', () async {
    SharedPreferences.setMockInitialValues({
      'base_url': 'https://legacy.example.com',
    });
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    addTearDown(container.dispose);

    container.read(settingsProvider);
    await Future<void>.delayed(Duration.zero);
    expect(prefs.getString('base_url'), isNull);
  });

  testWidgets('settings exposes music source management instead of resolver', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('音源管理'), findsOneWidget);
    final pickerSetting = find.byKey(
      const ValueKey('source-file-picker-setting'),
    );
    await tester.tap(
      find.descendant(of: pickerSetting, matching: find.byType(Switch)),
    );
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).useBuiltInSourceFilePicker, isTrue);
    expect(find.text('备份与恢复'), findsOneWidget);
    expect(find.text('WebDAV 同步'), findsNothing);
    expect(find.text('允许与其他 APP 共同播放'), findsOneWidget);
    expect(find.text('批量下载音质'), findsOneWidget);
    expect(find.text('扫描文件夹'), findsOneWidget);
    expect(find.text('浏览U盘'), findsNothing);
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    expect(find.text('URL 解析服务器'), findsNothing);
    expect(find.text('解析服务器健康检查'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('five settings cards keep their row order and live submenus', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    final cards = <String, List<String>>{
      '音源与搜索': ['音源管理', '音源内置文件选择器', '搜索源管理', '发现页平台顺序', '网络适配器'],
      '播放': [
        '在线播放音质',
        '均衡器',
        '淡入/淡出',
        '定时关闭音乐',
        '启动后自动播放',
        '允许与其他 APP 共同播放',
        '蓝牙歌词',
      ],
      '下载与本地音乐': ['批量下载音质', '下载位置', '扫描文件夹'],
      '外观与界面': ['主题与配色', '播放界面设置', '导航模式', '车机与平板', '跳过启动页'],
      '关于': ['检查更新', '备份与恢复', '调试模式'],
    };
    expect(
      tester
          .widgetList<SettingsCard>(find.byType(SettingsCard))
          .map((w) => w.title),
      cards.keys,
    );
    for (final entry in cards.entries) {
      final card = find.byWidgetPredicate(
        (w) => w is SettingsCard && w.title == entry.key,
      );
      final positions = [
        for (final title in entry.value)
          tester
              .getTopLeft(find.descendant(of: card, matching: find.text(title)))
              .dy,
      ];
      expect(positions, orderedEquals([...positions]..sort()));
    }
    expect(find.text('车机界面大小'), findsNothing);
    expect(find.text('日志控制台'), findsNothing);
    expect(find.text('动态流光'), findsNothing);
    await _openSettingsRow(tester, '车机与平板');
    final carSwitch = find.descendant(
      of: find.byKey(const ValueKey('car-display-setting')),
      matching: find.byType(Switch),
    );
    await tester.tap(carSwitch);
    await tester.pumpAndSettle();
    expect(find.text('车机界面大小'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('car-display-size-menu-anchor')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('car-display-size-menu-option-1.25')),
    );
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).carDisplaySize, 1.25);
    await tester.tap(carSwitch);
    await tester.pumpAndSettle();
    expect(find.text('车机界面大小'), findsNothing);
    await _openSettingsRow(tester, '完成');

    await _openSettingsRow(tester, '主题与配色');
    await _openSettingsRow(tester, '深色');
    expect(container.read(settingsProvider).themeMode, ThemeMode.dark);
    expect(find.text('歌单详情动态配色'), findsOneWidget);
    await _openSettingsRow(tester, '完成');
    await _openSettingsRow(tester, '播放界面设置');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('flowing-light-setting')),
        matching: find.byType(Switch),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).flowingLightEnabled, isFalse);
    await _openSettingsRow(tester, '完成');

    for (final pair in [('下载位置', '恢复默认'), ('扫描文件夹', '恢复为下载位置')]) {
      await _openSettingsRow(tester, pair.$1);
      expect(find.text('当前文件夹'), findsOneWidget);
      expect(find.text(pair.$2), findsOneWidget);
      expect(find.text('浏览U盘'), findsOneWidget);
      await _openSettingsRow(tester, '完成');
    }
    final debug = find.descendant(
      of: find.byType(DebugModeRow),
      matching: find.byType(Switch),
    );
    await tester.ensureVisible(debug);
    await tester.pumpAndSettle();
    await tester.tap(debug);
    await tester.pumpAndSettle();
    expect(find.text('日志控制台'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'crossfade responds to slider, buttons and keyboard and survives restart',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const SettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已关闭 · 0 秒'), findsOneWidget);
      await _openSettingsRow(tester, '淡入/淡出');
      final slider = find.byType(Slider);
      final control = tester.widget<Slider>(slider);
      expect((control.min, control.max, control.divisions), (0, 12, null));
      expect(control.label, '关闭');
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.remove_rounded),
            )
            .onPressed,
        isNull,
      );
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await gesture.moveBy(const Offset(25, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(7, 0));
      await tester.pump();
      final dragged = tester.widget<Slider>(slider);
      expect(dragged.value % 1, isNot(0));
      expect(
        dragged.label,
        '${double.parse(dragged.value.toStringAsFixed(1))} 秒',
      );
      expect(
        SliderTheme.of(tester.element(slider)).showValueIndicator,
        ShowValueIndicator.onDrag,
      );
      expect(container.read(settingsProvider).crossfadeMilliseconds, 0);
      await gesture.up();
      await tester.pumpAndSettle();
      final draggedMs = (dragged.value * 1000).round();
      expect(container.read(settingsProvider).crossfadeMilliseconds, draggedMs);
      await tester.tap(find.byTooltip('减小过渡时长（秒）'));
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).crossfadeMilliseconds,
        draggedMs - 1000,
      );
      await tester.tap(find.byTooltip('增大过渡时长（秒）'));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).crossfadeMilliseconds, draggedMs);
      final input = find.byType(TextField);
      await tester.enterText(input, '2.36');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).label, '2.4 秒');
      expect(container.read(settingsProvider).crossfadeMilliseconds, 2360);
      await tester.enterText(input, '20');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).crossfadeMilliseconds, 12000);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.add_rounded),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(input, '0.006');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).label, '小于 0.1 秒');
      expect(container.read(settingsProvider).crossfadeMilliseconds, 6);
      final formatLabel = tester.widget<Slider>(slider).semanticFormatterCallback!;
      expect(formatLabel(0), '关闭');
      expect(formatLabel(0.0002), '小于 0.1 秒');
      expect(formatLabel(0.099), '小于 0.1 秒');
      expect(formatLabel(0.1), '0.1 秒');
      await _openSettingsRow(tester, '完成');
      expect(find.text('小于 0.1 秒 · 歌曲切换时交叠播放'), findsOneWidget);
      final restored = _settingsContainer(prefs);
      addTearDown(restored.dispose);
      expect(restored.read(settingsProvider).crossfadeMilliseconds, 6);
      await _openSettingsRow(tester, '淡入/淡出');
      await tester.enterText(input, '0');
      await _openSettingsRow(tester, '完成');
      expect(find.text('已关闭 · 0 秒'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'search sources and playback quality persist and reject an empty set',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      final notifier = container.read(settingsProvider.notifier);

      expect(
        await notifier.setSearchSourceEnabled(MusicSource.mg, true),
        isTrue,
      );
      await notifier.setOnlinePlaybackQuality(OnlinePlaybackQuality.lossless);
      await notifier.setBatchDownloadQuality(OnlinePlaybackQuality.high);
      for (final source in [MusicSource.kg, MusicSource.tx, MusicSource.wy]) {
        expect(await notifier.setSearchSourceEnabled(source, false), isTrue);
      }
      expect(
        await notifier.setSearchSourceEnabled(MusicSource.kw, false),
        isTrue,
      );
      expect(
        await notifier.setSearchSourceEnabled(MusicSource.mg, false),
        isFalse,
      );

      expect(container.read(settingsProvider).enabledSearchSources, {
        MusicSource.mg,
      });
      container.dispose();

      final restored = _settingsContainer(prefs);
      addTearDown(restored.dispose);
      expect(restored.read(settingsProvider).enabledSearchSources, {
        MusicSource.mg,
      });
      expect(
        restored.read(settingsProvider).onlinePlaybackQuality,
        OnlinePlaybackQuality.lossless,
      );
      expect(
        restored.read(settingsProvider).batchDownloadQuality,
        OnlinePlaybackQuality.high,
      );
    },
  );

  test(
    'local music scan folder follows download folder until customized',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      final notifier = container.read(settingsProvider.notifier);

      await notifier.setDownloadDir('/storage/emulated/0/Music/Downloads');
      expect(
        container.read(settingsProvider).localMusicDir,
        '/storage/emulated/0/Music/Downloads',
      );

      await notifier.setLocalMusicDir('/storage/1234-5678/Music');
      await notifier.setDownloadDir('/storage/emulated/0/Music/NewDownloads');

      expect(
        container.read(settingsProvider).downloadDir,
        '/storage/emulated/0/Music/NewDownloads',
      );
      expect(
        container.read(settingsProvider).localMusicDir,
        '/storage/1234-5678/Music',
      );
      container.dispose();

      final restored = _settingsContainer(prefs);
      addTearDown(restored.dispose);
      expect(
        restored.read(settingsProvider).localMusicDir,
        '/storage/1234-5678/Music',
      );
    },
  );

  test(
    'saved search source codes are ordered, deduplicated, and sanitized',
    () {
      expect(decodeEnabledSearchSources(['mg', 'unknown', 'mg', 'all', 'kw']), {
        MusicSource.kw,
        MusicSource.mg,
      });
      expect(decodeEnabledSearchSources([]), kDefaultEnabledSearchSources);
    },
  );

  group('online playback quality resolution', () {
    test('keeps highest behavior and honors an exact preference', () {
      final music = _musicWithQualities([
        Quality.k128,
        Quality.flac,
        Quality.k320,
      ]);

      expect(
        music.playbackQualityFor(OnlinePlaybackQuality.highest),
        Quality.flac,
      );
      expect(
        music.playbackQualityFor(OnlinePlaybackQuality.high),
        Quality.k320,
      );
    });

    test(
      'falls down first, then up when the preferred quality is unavailable',
      () {
        expect(
          _musicWithQualities([
            Quality.hires,
            Quality.k320,
            Quality.k128,
          ]).playbackQualityFor(OnlinePlaybackQuality.lossless),
          Quality.k320,
        );
        expect(
          _musicWithQualities([
            Quality.flac,
          ]).playbackQualityFor(OnlinePlaybackQuality.high),
          Quality.flac,
        );
      },
    );

    test('uses 128K when a track has no advertised qualities', () {
      expect(
        _musicWithQualities(
          const [],
        ).playbackQualityFor(OnlinePlaybackQuality.hires),
        Quality.k128,
      );
    });
  });

  testWidgets(
    'source filter stays full width and slides smoothly between sources',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: SourceFilterChips()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('咪咕'), findsNothing);
      final defaultWidth = tester
          .getSize(find.byKey(const ValueKey('search-source-filter')))
          .width;
      final scaffoldWidth = tester.getSize(find.byType(Scaffold)).width;
      expect(defaultWidth, closeTo(scaffoldWidth - 24, 0.01));

      final indicator = find.byKey(const ValueKey('search-source-indicator'));
      final initialLeft = tester.getTopLeft(indicator).dx;
      await tester.tap(find.byKey(const ValueKey('search-source-tx')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final middleLeft = tester.getTopLeft(indicator).dx;
      expect(middleLeft, greaterThan(initialLeft));
      await tester.pumpAndSettle();
      final finalLeft = tester.getTopLeft(indicator).dx;
      expect(middleLeft, lessThan(finalLeft));

      await container
          .read(settingsProvider.notifier)
          .setSearchSourceEnabled(MusicSource.mg, true);
      await tester.pumpAndSettle();

      expect(find.text('咪咕'), findsOneWidget);
      final expandedWidth = tester
          .getSize(find.byKey(const ValueKey('search-source-filter')))
          .width;
      expect(expandedWidth, closeTo(defaultWidth, 0.01));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'anchored menu uses the staggered Material radio menu animation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const SettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.cable_rounded), findsOneWidget);
      expect(find.byIcon(Icons.manage_search_rounded), findsOneWidget);
      expect(find.byIcon(Icons.high_quality_rounded), findsOneWidget);
      expect(Icons.cable_rounded.fontFamily, 'MaterialIcons');
      expect(Icons.manage_search_rounded.fontFamily, 'MaterialIcons');
      expect(Icons.high_quality_rounded.fontFamily, 'MaterialIcons');

      final anchor = find.byKey(const ValueKey('network-adapter-menu-anchor'));
      // This fixed-top animation assertion exercises a downward-opening menu.
      // Keep the anchor in the upper half even when preceding settings grow.
      await Scrollable.ensureVisible(tester.element(anchor), alignment: 0.25);
      await tester.pumpAndSettle();
      final anchorRect = tester.getRect(anchor);
      expect(anchorRect.center.dy, lessThan(450));
      final leftTouch = Offset(anchorRect.left + 12, anchorRect.center.dy);
      await tester.tapAt(leftTouch);
      await tester.pump();

      final panel = find.byKey(const ValueKey('network-adapter-menu-panel'));
      final fade = find.byKey(const ValueKey('network-adapter-menu-fade'));
      final reveal = find.byKey(const ValueKey('network-adapter-menu-reveal'));
      final firstOptionFade = find.byKey(
        const ValueKey('network-adapter-menu-option-system-fade'),
      );
      final middleOptionFade = find.byKey(
        const ValueKey('network-adapter-menu-option-io-fade'),
      );
      final lastOptionFade = find.byKey(
        const ValueKey('network-adapter-menu-option-native-fade'),
      );
      expect(panel, findsOneWidget);
      final initialPanelRect = tester.getRect(panel);
      expect(
        tester.widget<FadeTransition>(fade).opacity.value,
        closeTo(0, 0.001),
      );
      expect(tester.widget<Align>(reveal).heightFactor, closeTo(0, 0.001));
      expect(
        tester.widget<FadeTransition>(firstOptionFade).opacity.value,
        closeTo(0, 0.001),
      );

      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester.widget<FadeTransition>(fade).opacity.value,
        closeTo(1, 0.001),
      );
      expect(tester.widget<Align>(reveal).heightFactor, inExclusiveRange(0, 1));

      await tester.pump(const Duration(milliseconds: 75));
      expect(
        tester.widget<FadeTransition>(firstOptionFade).opacity.value,
        closeTo(0.5, 0.001),
      );
      expect(
        tester.widget<FadeTransition>(middleOptionFade).opacity.value,
        closeTo(0, 0.001),
      );
      expect(
        tester.widget<FadeTransition>(lastOptionFade).opacity.value,
        closeTo(0, 0.001),
      );

      await tester.pump(const Duration(milliseconds: 125));
      expect(
        tester.widget<FadeTransition>(firstOptionFade).opacity.value,
        closeTo(1, 0.001),
      );
      expect(
        tester.widget<FadeTransition>(middleOptionFade).opacity.value,
        closeTo(0.5, 0.001),
      );
      expect(
        tester.widget<FadeTransition>(lastOptionFade).opacity.value,
        closeTo(0, 0.001),
      );

      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        tester.widget<FadeTransition>(fade).opacity.value,
        closeTo(1, 0.001),
      );
      expect(tester.widget<Align>(reveal).heightFactor, closeTo(1, 0.001));
      expect(
        tester.widget<FadeTransition>(lastOptionFade).opacity.value,
        closeTo(1, 0.001),
      );
      final leftPanelRect = tester.getRect(panel);
      expect(leftPanelRect.width, closeTo(initialPanelRect.width, 0.01));
      expect(leftPanelRect.top, closeTo(initialPanelRect.top, 0.01));
      expect(leftPanelRect.left, greaterThanOrEqualTo(leftTouch.dx));
      expect(leftPanelRect.width, lessThanOrEqualTo(184.01));

      await tester.tapAt(const Offset(420, 880));
      await tester.pumpAndSettle();
      expect(panel, findsNothing);

      final rightTouch = Offset(anchorRect.right - 12, anchorRect.center.dy);
      await tester.tapAt(rightTouch);
      await tester.pumpAndSettle();
      final rightPanelRect = tester.getRect(panel);
      expect(rightPanelRect.right, lessThanOrEqualTo(rightTouch.dx));
      await tester.tap(
        find.byKey(const ValueKey('network-adapter-menu-option-io')),
      );
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).networkAdapterMode,
        NetworkAdapterMode.io,
      );
      expect(panel, findsNothing);
      await tester.pump(const Duration(seconds: 4));

      final qualityAnchor = find.byKey(
        const ValueKey('online-quality-menu-anchor'),
      );
      await tester.tap(qualityAnchor);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      final qualityPanel = find.byKey(
        const ValueKey('online-quality-menu-panel'),
      );
      expect(qualityPanel, findsOneWidget);
      expect(tester.getSize(qualityPanel).width, lessThanOrEqualTo(184.01));
      await tester.tap(
        find.byKey(const ValueKey('online-quality-menu-option-flac')),
      );
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).onlinePlaybackQuality,
        OnlinePlaybackQuality.lossless,
      );
      expect(qualityPanel, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 4));
    },
  );

  testWidgets('search source management stays open for multi-selection', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    final anchor = find.byKey(const ValueKey('search-source-menu-anchor'));
    await tester.tap(anchor);
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('search-source-menu-panel'));
    final miguOption = find.byKey(
      const ValueKey('search-source-menu-option-mg'),
    );
    expect(panel, findsOneWidget);
    expect(tester.getSize(panel).width, lessThanOrEqualTo(184.01));
    expect(tester.getSize(miguOption).height, closeTo(48, 0.01));
    await tester.tap(miguOption);
    await tester.pumpAndSettle();

    expect(
      container.read(settingsProvider).enabledSearchSources,
      contains(MusicSource.mg),
    );
    expect(panel, findsOneWidget);
    expect(miguOption, findsOneWidget);
    expect(
      find.descendant(
        of: miguOption,
        matching: find.byIcon(Icons.check_box_rounded),
      ),
      findsOneWidget,
    );
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _openSettingsRow(WidgetTester tester, String title) async {
  final target = find.text(title).last;
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

ProviderContainer _settingsContainer(SharedPreferences prefs) {
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

MusicInfo _musicWithQualities(List<Quality> qualities) {
  return MusicInfo(
    id: 'quality-test',
    name: 'Quality test',
    singer: 'Tester',
    source: MusicSource.wy,
    interval: '03:00',
    meta: MusicMeta(
      songId: 'quality-test',
      albumName: 'Test album',
      qualitys: [for (final quality in qualities) QualityOption(type: quality)],
      raw: const {},
    ),
    raw: const {},
  );
}
