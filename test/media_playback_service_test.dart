import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/audio_score_auto_aligner.dart';
import 'package:violin_practice_companion/services/media_playback_service.dart';

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

    final sorted = MediaPlaybackService.sortAnchors(anchors);

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
        MediaPlaybackService.dropDegenerateSegments(
            MediaPlaybackService.sortAnchors(anchors));

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

  group('recordingLeadIn', () {
    // A steady recording: score runs at 2 score-s per audio-s, first note at
    // 4s in the file (a 4s intro), anchors every bar.
    const anchors = [
      ScoreAudioAnchor(0, 4.0),
      ScoreAudioAnchor(2000, 5.0),
      ScoreAudioAnchor(4000, 6.0),
      ScoreAudioAnchor(6000, 7.0),
      ScoreAudioAnchor(8000, 8.0),
    ];

    LeadInPlan plan(
            {double start = 0,
            double count = 3,
            bool top = true,
            bool preroll = false,
            double speed = 1,
            List<ScoreAudioAnchor> a = anchors}) =>
        MediaPlaybackService.recordingLeadIn(
            anchors: a,
            startScoreSec: start,
            countScoreSec: count,
            fromBeginning: top,
            preroll: preroll,
            speed: speed)!;

    test('a long intro carries the count: no wait', () {
      final p = plan(); // 3 score-s = 1.5 audio-s of count
      expect(p.seekAudioSec, 0);
      expect(p.waitRealSec, 0);
      expect(p.entryAudioSec, closeTo(4, 1e-9));
      expect(p.countStartAudioSec, closeTo(2.5, 1e-9));
      expect(p.scorePerAudio, closeTo(2, 1e-9));
    });

    test('a short intro is topped up with silence', () {
      final p = plan(count: 10); // 5 audio-s of count, 4s of intro
      expect(p.seekAudioSec, 0);
      expect(p.waitRealSec, closeTo(1, 1e-9));
    });

    test('no intro: the whole count is silent', () {
      final shifted = [
        for (final a in anchors) ScoreAudioAnchor(a.scoreMs, a.audioSec - 4)
      ];
      final p = plan(a: shifted);
      expect(p.waitRealSec, closeTo(1.5, 1e-9));
    });

    test('mid-piece, silent: wait at the entry', () {
      final p = plan(start: 4, top: false);
      expect(p.seekAudioSec, closeTo(6, 1e-9));
      expect(p.waitRealSec, closeTo(1.5, 1e-9));
    });

    test('mid-piece, pre-roll: start a count early', () {
      final p = plan(start: 4, top: false, preroll: true);
      expect(p.seekAudioSec, closeTo(4.5, 1e-9));
      expect(p.waitRealSec, 0);
    });

    test('pre-roll past the file start is clamped and topped up', () {
      final p = plan(start: 4, top: false, preroll: true, count: 16);
      expect(p.seekAudioSec, 0);
      expect(p.waitRealSec, closeTo(2, 1e-9)); // count starts at -2
    });

    test('half speed doubles the silent wait', () {
      final p = plan(start: 4, top: false, speed: 0.5);
      expect(p.waitRealSec, closeTo(3, 1e-9));
    });

    test('tempo is local to the entry, not the whole recording', () {
      // Slow first two bars (1 score-s per audio-s), then fast.
      const varied = [
        ScoreAudioAnchor(0, 0.0),
        ScoreAudioAnchor(2000, 2.0),
        ScoreAudioAnchor(4000, 4.0),
        ScoreAudioAnchor(8000, 5.0),
        ScoreAudioAnchor(12000, 6.0),
      ];
      expect(
          MediaPlaybackService.localScorePerAudio(varied, 0,
              windowScoreSec: 4),
          closeTo(1, 1e-9));
      expect(
          MediaPlaybackService.localScorePerAudio(varied, 4,
              windowScoreSec: 8),
          closeTo(4, 1e-9));
    });

    test('nothing to place with fewer than two anchors', () {
      expect(
          MediaPlaybackService.recordingLeadIn(
              anchors: const [ScoreAudioAnchor(0, 1)],
              startScoreSec: 0,
              countScoreSec: 3,
              fromBeginning: true,
              preroll: false),
          isNull);
    });
  });
}
