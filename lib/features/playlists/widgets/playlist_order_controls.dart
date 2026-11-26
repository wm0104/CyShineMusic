import 'package:flutter/material.dart';

/// Delayed native reorder recognizer: scrolling, taps and horizontal slidable
/// gestures still compete normally, while the whole row/card is hit-testable.
class PlaylistOrderDragRegion extends StatelessWidget {
  const PlaylistOrderDragRegion({
    super.key,
    required this.index,
    required this.enabled,
    required this.child,
  });

  final int index;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) => enabled
      ? ReorderableDelayedDragStartListener(
          index: index,
          child: child,
        )
      : child;
}
