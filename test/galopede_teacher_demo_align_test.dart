// Regression test for the teacher-demo alignment pipeline against a real
// recording: docs/photos_no_share/galopede_video.MOV, a play-through of
// Galopede on mandolin. Author-supplied, gitignored — skips gracefully where
// absent. See docs/photos_no_share/galopede_converted.musicxml (produced by
// running the app's real bundled abcjs converter over assets/abc/Galopede.abc
// via Node, headlessly — same JS the app runs on-device) and
// galopede_audio.wav (audio track extracted from the .MOV via afconvert).
//
// This recording is the pipeline's hardest real case and the reason for the
// front-end and skip-penalty changes documented in
// docs/audio-sync-dtw-interior-gaps.md: it is quiet, and it carries a low hum
// that holds 81% of the recording's energy below 200 Hz. Before those changes
// the alignment put its first anchor at 22.0s when the first note is at 3s,
// and declared the tune finished at 40.6s when it runs to 49s — so the
// highlight raced through the whole score during the middle of the recording
// and had nothing left to do for the rest of it.
//
// GROUND TRUTH is the author's, by ear, and is what the assertions below
// encode. There is no spoken narration anywhere in the recording (an earlier
// write-up of this file claimed a 22s spoken intro and spoken section
// announcements; that was wrong):
//
//   first note (pickup)          3s
//   A part repeats              15s
//   B part begins               25s
//   C part begins               37s
//   tune ends, loops to the top 49s
//   video cuts off              54s
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/audio_score_auto_aligner.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/musicxml_normalizer.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

/// Performance-measure index -> the audio second it should land on.
///
/// The ABC is a pickup measure plus 24 written measures, with the repeat
/// spanning measures 1-8, so performance order is: pickup (0), A (1-8),
/// A again (9-16), B (17-24), C (25-32) — 33 measures.
const _groundTruth = <int, double>{
  0: 3.0, // pickup, the first note
  9: 15.0, // A part, second time
  17: 25.0, // B part
  25: 37.0, // C part
};

/// The author's timings are by ear against section boundaries, and a measure
/// here lasts ~1.4s, so this is about one measure of slack — tight enough to
/// fail every alignment the old pipeline produced (its mean error was 18.7s)
/// without encoding more precision than the ground truth has.
const _toleranceSeconds = 1.5;

void main() {
  final musicXmlFile =
      File('docs/photos_no_share/galopede_converted.musicxml');
  final wavFile = File('docs/photos_no_share/galopede_audio.wav');
  if (!musicXmlFile.existsSync() || !wavFile.existsSync()) {
    test('galopede teacher-demo align (skipped: assets not present)', () {});
    return;
  }

  test('auto-alignment against the real Galopede teacher-demo recording', () {
    final golden = musicXmlFile.readAsStringSync();
    final piece =
        MusicXmlParser().parse(MusicXmlNormalizer.toSoundingPitch(golden));
    expect(piece.measures.length, 25);

    final wavBytes = wavFile.readAsBytesSync();
    final aligner = AudioScoreAutoAligner(midiGenerator: MidiGenerator.forTest());
    final result = aligner.align(piece, wavBytes);

    // ignore: avoid_print
    print('generationBpm=${result.generationBpm} '
        'averageDtwCost=${result.averageDtwCost.toStringAsFixed(4)} '
        'hasCompressedAnchors=${result.hasCompressedAnchors} '
        'anchorCount=${result.anchors.length}');
    for (var i = 0; i < result.anchors.length; i++) {
      final a = result.anchors[i];
      final pace = i == 0
          ? double.nan
          : (a.audioSec - result.anchors[i - 1].audioSec) /
              (a.scoreMs - result.anchors[i - 1].scoreMs);
      final truth = _groundTruth[i];
      // ignore: avoid_print
      print('anchor $i: scoreMs=${a.scoreMs.toStringAsFixed(0)} '
          'audioSec=${a.audioSec.toStringAsFixed(3)} '
          'pace=${pace.toStringAsFixed(4)}'
          '${truth == null ? '' : '  <- truth $truth, '
              'err ${(a.audioSec - truth).abs().toStringAsFixed(2)}s'}');
    }

    expect(result.anchors, hasLength(33),
        reason: 'one anchor per repeat-expanded performance measure');
    for (var i = 1; i < result.anchors.length; i++) {
      expect(result.anchors[i].audioSec,
          greaterThanOrEqualTo(result.anchors[i - 1].audioSec));
      expect(result.anchors[i].scoreMs,
          greaterThan(result.anchors[i - 1].scoreMs));
    }

    // The section boundaries the author timed by ear.
    var totalError = 0.0;
    for (final entry in _groundTruth.entries) {
      final actual = result.anchors[entry.key].audioSec;
      totalError += (actual - entry.value).abs();
      expect(actual, closeTo(entry.value, _toleranceSeconds),
          reason: 'performance measure ${entry.key} should land near '
              '${entry.value}s of audio');
    }
    // ignore: avoid_print
    print('mean absolute error vs ground truth: '
        '${(totalError / _groundTruth.length).toStringAsFixed(2)}s');

    // The recording loops back to the top of the tune after it ends at 49s.
    // That loop-back is a genuine repetition of the A part, so it resembles
    // the score and the open-end boundary has to discard it on cost rather
    // than on novelty — the last anchor must stay inside the tune proper.
    expect(result.anchors.last.audioSec, lessThan(49.0),
        reason: 'the final measure must not be pushed into the loop-back');
    expect(result.anchors.last.audioSec, greaterThan(44.0),
        reason: 'the final measure should be near the end of the tune');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
