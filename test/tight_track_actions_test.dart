import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cy_shine_music/core/ui/tight_track_actions.dart';

void main() {
  test('action extent follows applicable count and actual row width', () {
    expect(tightTrackActionExtent(1, 366), closeTo(68 / 366, .001));
    expect(tightTrackActionExtent(2, 366), closeTo(136 / 366, .001));
    expect(tightTrackActionExtent(4, 366), lessThan(.88));
    expect(tightTrackActionExtent(4, 296), lessThan(.96));
    expect(tightTrackActionExtent(2, 800), lessThan(tightTrackActionExtent(2, 366)));
    expect(tightTrackActionExtent(2, 366, textScale: 1.3), greaterThan(tightTrackActionExtent(2, 366)));
    expect(tightTrackActionExtent(0, 366), 0);
    expect(tightTrackActionExtent(2, 0), 0);
    expect(tightTrackActionExtent(2, double.infinity), 0);
  });

  test('four original labels keep recognisable text and 44px touch width at 320px', () {
    const labels = ['添加到歌单', '移动到歌单', '更换匹配', '移除'];
    final flex = labels.map(tightTrackActionFlex).toList();
    final sum = flex.reduce((a, b) => a + b);
    final paneWidth = tightTrackActionExtent(4, 296) * 296;
    for (var i = 0; i < labels.length; i++) {
      final width = paneWidth * flex[i] / sum;
      expect(width, greaterThanOrEqualTo(44));
      expect(width - tightTrackActionPadding.horizontal,
          greaterThanOrEqualTo(labels[i].runes.length * 14));
    }
    expect(tightTrackActionPadding, const EdgeInsets.symmetric(horizontal: 2));
  });
}
