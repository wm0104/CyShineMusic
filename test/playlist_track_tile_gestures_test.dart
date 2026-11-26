import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cy_shine_music/core/ui/tight_track_actions.dart';
import 'package:cy_shine_music/features/playlists/playlist_models.dart';
import 'package:cy_shine_music/features/playlists/resolved_playlist_track.dart';
import 'package:cy_shine_music/features/playlists/widgets/playlist_order_controls.dart';
import 'package:cy_shine_music/features/playlists/widgets/playlist_track_tile.dart';

void main() {
  testWidgets('preinstalled row drag listener preserves taps download and four swipe actions', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 720);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    var played = 0;
    var downloaded = 0;
    var reordered = 0;
    var added = 0;
    await tester.pumpWidget(ProviderScope(child: MaterialApp(home: Scaffold(
      body: CustomScrollView(slivers: [SliverReorderableList(
        itemCount: 20,
        onReorderItem: (_, _) => reordered++,
        itemBuilder: (context, index) => PlaylistOrderDragRegion(
          key: ValueKey('row-$index'), index: index, enabled: true,
          child: PlaylistTrackTile(
            playlistId: 'gesture-test', index: index,
            item: ResolvedPlaylistTrack(
              track: PlaylistTrack(musicId: '$index', name: 'Track $index',
                singer: 'Artist', albumName: '', sourceCode: 'local', qualityCode: '128k'),
              localEntry: null, queueEntry: null,
            ),
            playing: false, batchMode: false, batchSubmitting: false,
            selected: false, onToggleSelected: () {}, onPlay: () => played++,
            onDownload: () => downloaded++, onRemove: () {}, onMatch: () {},
            onAddToPlaylist: () => added++, onMoveToPlaylist: () {},
          ),
        ),
      )]),
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Track 0'));
    await tester.pumpAndSettle();
    expect(played, 1);
    final row = find.byKey(const ValueKey('row-0'));
    final download = find.descendant(of: row,
      matching: find.byKey(const ValueKey('playlist-download-action')));
    expect(tester.getSize(download), const Size(44, 44));
    await tester.tap(download);
    await tester.pumpAndSettle();
    expect(downloaded, 1);
    expect(reordered, 0);

    final height = tester.getSize(row).height;
    await tester.drag(find.text('Track 0'), const Offset(-280, 0));
    await tester.pumpAndSettle();
    for (final label in ['添加到歌单', '移动到歌单', '更换匹配', '移除']) {
      expect(find.text(label).hitTestable(), findsOneWidget);
    }
    final pane = tester.widget<ActionPane>(find.descendant(of: row, matching: find.byType(ActionPane)));
    expect(pane.motion, isA<BehindMotion>());
    expect(pane.extentRatio, tightTrackActionExtent(4, 320));
    expect(tester.getSize(row).height, height);
    await tester.tap(find.text('添加到歌单').hitTestable());
    await tester.pumpAndSettle();
    expect(added, 1);
    expect(reordered, 0);

    await tester.drag(find.text('Track 2'), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('Track 0').hitTestable(), findsNothing);
    expect(reordered, 0);
    expect(tester.takeException(), isNull);
  });
}
