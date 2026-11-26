import 'package:flutter/widgets.dart';

/// Fraction of a track row revealed by its applicable trailing actions.
/// Use the actual row width (LayoutBuilder), not the screen width.
double tightTrackActionExtent(
  int actionCount,
  double width, {
  double textScale = 1,
}) {
  if (actionCount <= 0 || !width.isFinite || width <= 0) return 0;
  final actionWidth = 68.0 * textScale.clamp(1.0, 2.0);
  return (actionCount * actionWidth / width).clamp(0.0, 0.88).toDouble();
}

/// Give the original five-character actions room without wasting the same
/// width on “移除”; the minimum weight keeps its touch target usable.
int tightTrackActionFlex(String label) =>
    (label.runes.length + 1).clamp(4, 6).toInt();

const tightTrackActionPadding = EdgeInsets.symmetric(horizontal: 2);
