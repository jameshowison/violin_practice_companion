import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/rendered_score_playback_service.dart';

void main() {
  test('three renders around the performance tempo', () {
    expect(RenderedScorePlaybackService.renderTempos(100), [67, 85, 107]);
  });

  test('60-120% of P plays within about 12% of a render', () {
    final renders = RenderedScorePlaybackService.renderTempos(100);
    for (var bpm = 60; bpm <= 120; bpm++) {
      final r = RenderedScorePlaybackService.nearestRender(renders, bpm);
      final rate = bpm / r;
      expect(rate, inInclusiveRange(0.88, 1.13), reason: '$bpm bpm on $r');
    }
  });

  test('nearest by ratio, not by difference', () {
    // 76 is 9 from 67 and 9 from 85; by ratio it's nearer 85 (1.118 vs 1.134).
    expect(RenderedScorePlaybackService.nearestRender([67, 85, 107], 76), 85);
    expect(RenderedScorePlaybackService.nearestRender([67, 85, 107], 20), 67);
    expect(RenderedScorePlaybackService.nearestRender([67, 85, 107], 208), 107);
  });
}
