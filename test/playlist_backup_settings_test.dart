import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/core/sync/playlist_backup_service.dart';
import 'package:cy_shine_music/features/settings/settings_page.dart';
import 'package:cy_shine_music/features/settings/widgets/settings_action.dart';
import 'package:cy_shine_music/features/shell/shell_toolbar_visibility.dart';
import 'package:cy_shine_music/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('About opens a scrollable backup picker above the shell', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    late _CloudBackups service;
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        playlistBackupServiceProvider.overrideWith(
          (ref) => service = _CloudBackups(ref),
        ),
      ],
    );
    addTearDown(container.dispose);
    final rootObserver = _PopupObserver();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          navigatorObservers: [rootObserver],
          home: Navigator(
            onGenerateRoute: (_) =>
                MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final about = find.byWidgetPredicate(
      (widget) => widget is SettingsCard && widget.title == '关于',
    );
    final backup = find.descendant(
      of: about,
      matching: find.byKey(const ValueKey('backup-and-restore-setting')),
    );
    expect(
      find.descendant(of: about, matching: find.byType(DebugModeRow)),
      findsOneWidget,
    );
    expect(find.text('WebDAV 同步'), findsNothing);
    expect(find.text('从云端恢复'), findsNothing);
    await tester.ensureVisible(backup);
    await tester.pumpAndSettle();
    await tester.tap(backup);
    await tester.pumpAndSettle();
    expect(rootObserver.popupCount, 1);
    expect(container.read(shellToolbarVisibleProvider), isFalse);
    expect(find.text('WebDAV 同步'), findsOneWidget);
    expect(find.text('导出备份'), findsOneWidget);
    expect(find.text('导入备份'), findsOneWidget);
    expect(find.text('上传到云端'), findsOneWidget);

    final restore = find.text('从云端恢复');
    await tester.ensureVisible(restore);
    await tester.pumpAndSettle();
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(rootObserver.popupCount, 2);

    final last = find.text(_CloudBackups.names.last);
    final cloudList = find.descendant(
      of: find.byKey(const ValueKey('cloud-backup-list')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(last, 250, scrollable: cloudList);
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(service.restored, _CloudBackups.names.last);
    expect(container.read(shellToolbarVisibleProvider), isFalse);

    await tester.tapAt(const Offset(20, 30));
    await tester.pumpAndSettle();
    expect(container.read(shellToolbarVisibleProvider), isTrue);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

class _CloudBackups extends PlaylistBackupService {
  _CloudBackups(super.ref);

  static final names = [
    for (var day = 20; day > 0; day--)
      '栖弦备份-2026-11-${day.toString().padLeft(2, '0')}.json',
  ];
  String? restored;

  @override
  Future<List<String>> listCloud() async => names;

  @override
  Future<int> restoreCloud(String name) async {
    restored = name;
    return 1;
  }
}

class _PopupObserver extends NavigatorObserver {
  int popupCount = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) popupCount++;
  }
}
