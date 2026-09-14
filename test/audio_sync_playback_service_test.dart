import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/audio_score_auto_aligner.dart';
import 'package:violin_practice_companion/services/audio_sync_playback_service.dart';

void main() {
  test('sortAnchors orders by audioSec and breaks ties on scoreMs', () {
    // Deliberately out of order, with a tied audioSec pair (as can occur at a
    // chroma-identical repeat boundary) whose scoreMs would otherwise be free
    // to land in either order after a plain sort.
    const anchors = [
      ScoreAudioAnchor(4000, 3.0),
      ScoreAudioAnchor(1000, 0.0),
      ScoreAudioAnchor(3000, 2.0),
      ScoreAudioAnchor(2000, 2.0),
    ];

    final sorted = AudioSyncPlaybackService.sortAnchors(anchors);

    for (var i = 1; i < sorted.length; i++) {
      expect(sorted[i].audioSec, greaterThanOrEqualTo(sorted[i - 1].audioSec));
      if (sorted[i].audioSec == sorted[i - 1].audioSec) {
        expect(sorted[i].scoreMs, greaterThan(sorted[i - 1].scoreMs));
      }
    }
    expect(sorted.map((a) => a.scoreMs), [1000, 2000, 3000, 4000]);
  });
}
