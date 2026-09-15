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

  group('dropDegenerateSegments', () {
    List<ScoreAudioAnchor> prepare(List<ScoreAudioAnchor> anchors) =>
        AudioSyncPlaybackService.dropDegenerateSegments(
            AudioSyncPlaybackService.sortAnchors(anchors));

    test('collapses an equal-audioSec run to its last anchor', () {
      // The shape a real alignment produces when the warp path advances
      // several reference frames without advancing through the audio.
      final kept = prepare(const [
        ScoreAudioAnchor(1000, 1.0),
        ScoreAudioAnchor(2000, 2.0),
        ScoreAudioAnchor(3000, 2.0),
        ScoreAudioAnchor(4000, 2.0),
        ScoreAudioAnchor(5000, 3.0),
      ]);

      expect(kept.map((a) => a.scoreMs), [1000, 4000, 5000]);
      expect(kept.map((a) => a.audioSec), [1.0, 2.0, 3.0]);
    });

    test('leaves every segment usable by the interpolators', () {
      final kept = prepare(const [
        ScoreAudioAnchor(0, 0.0),
        ScoreAudioAnchor(1000, 0.0),
        ScoreAudioAnchor(2000, 1.5),
        ScoreAudioAnchor(3000, 1.5),
        ScoreAudioAnchor(4000, 4.0),
      ]);

      for (var i = 1; i < kept.length; i++) {
        expect(kept[i].audioSec, greaterThan(kept[i - 1].audioSec));
        expect(kept[i].scoreMs, greaterThan(kept[i - 1].scoreMs));
      }
    });

    test('passes a clean anchor list through untouched', () {
      const clean = [
        ScoreAudioAnchor(0, 0.0),
        ScoreAudioAnchor(1000, 1.0),
        ScoreAudioAnchor(2000, 2.0),
      ];
      expect(prepare(clean).map((a) => a.scoreMs), [0, 1000, 2000]);
    });

    test('keeps two anchors rather than dropping below what playback needs',
        () {
      // Both anchors share an audioSec, so there is no non-degenerate pair to
      // keep — an unusable segment still beats disabling highlight tracking.
      final kept = prepare(const [
        ScoreAudioAnchor(0, 1.0),
        ScoreAudioAnchor(1000, 1.0),
      ]);
      expect(kept, hasLength(2));
    });
  });
}
