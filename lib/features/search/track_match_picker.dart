import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import 'search_controller.dart';
import 'search_page.dart';

Future<MusicInfo?> showTrackMatchPicker(
  BuildContext context, {
  required String title,
  required String artist,
  MusicSource? initialSource,
}) async {
  Widget buildPage(BuildContext context) => ProviderScope(
    overrides: [searchControllerProvider.overrideWith(SearchController.new)],
    child: SearchPage.songPicker(
      initialKeyword: '$title $artist'.trim(),
      initialSource: initialSource ?? MusicSource.all,
      onSongSelected: (music) => Navigator.of(context).pop(music),
    ),
  );

  return Navigator.of(context, rootNavigator: true).push(
    Theme.of(context).platform == TargetPlatform.iOS
        ? CupertinoPageRoute<MusicInfo>(builder: buildPage)
        : MaterialPageRoute<MusicInfo>(builder: buildPage),
  );
}
