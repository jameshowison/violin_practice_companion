// Regression test for the case that pins the UPPER bound on
// `DtwAligner.skipPenaltyPerFrame`: a recording whose intro quotes the tune.
//
// Lightly Row's bundled Play Along recording opens by restating the tune's
// first phrase before the performance proper (audio pitch classes run
// E, E, C#, C# over 2-5s and then E, C#, C#, D over 6-9s, which is the score's
// actual opening). So the intro genuinely resembles the score and the open
// boundary has to skip it on cost rather than on novelty.
//
// Raising the skip penalty is what breaks this: past ~0.23 the first anchor is
// dragged back into the intro, 6.57s -> 3.11s, and the cursor then sits on
// measure 1 for six seconds while the intro plays. That is the same symptom
// docs/audio-sync-dtw-open-boundaries.md was originally written to fix, and it
// went unnoticed when the penalty was first raised because nothing covered
// this recording. See docs/audio-sync-dtw-interior-gaps.md.
//
// `assets/audio/` is gitignored, so this skips gracefully where the recording
// is absent.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/audio_score_auto_aligner.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/musicxml_normalizer.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

void main() {
  final xmlFile = File('assets/striped/lightly_row_musescore.xml');
  final wavFile = File('assets/audio/lightly_row/melody.wav');
  if (!xmlFile.existsSync() || !wavFile.existsSync()) {
    test('lightly row intro align (skipped: assets not present)', () {});
    return;
  }

  test("an intro that quotes the tune is skipped, not matched", () {
    final piece = MusicXmlParser()
        .parse(MusicXmlNormalizer.toSoundingPitch(xmlFile.readAsStringSync()));
    final result = AudioScoreAutoAligner(midiGenerator: MidiGenerator.forTest())
        .align(piece, wavFile.readAsBytesSync());

    expect(result.anchors.length, greaterThan(4));

    // Pace is audio-seconds per score-millisecond over each segment. The
    // performance is steady, so the first segment should pace like the rest —
    // this is the assertion that fails when anchor 0 lands in the intro,
    // without needing a hand-labelled timestamp for the first note.
    final paces = <double>[];
    for (var i = 1; i < result.anchors.length; i++) {
      final scoreDelta =
          result.anchors[i].scoreMs - result.anchors[i - 1].scoreMs;
      if (scoreDelta > 0) {
        paces.add(
            (result.anchors[i].audioSec - result.anchors[i - 1].audioSec) /
                scoreDelta);
      }
    }
    final rest = paces.skip(1).toList()..sort();
    final median = rest[rest.length ~/ 2];
    final firstSegmentRatio = paces.first / median;

    // ignore: avoid_print
    print('lightly row: bpm=${result.generationBpm} '
        'a0=${result.anchors.first.audioSec.toStringAsFixed(3)} '
        'firstSegmentRatio=${firstSegmentRatio.toStringAsFixed(2)}x '
        'compressed=${result.hasCompressedAnchors}');

    expect(firstSegmentRatio, closeTo(1.0, 0.5),
        reason: 'the first segment must pace like the rest of the piece; a '
            'much larger ratio means anchor 0 was pulled back into the intro '
            '(2.4x when this last regressed)');
    // The intro runs to roughly 6.5s. Being early is the failure mode here,
    // so this is a floor as much as a sanity check.
    expect(result.anchors.first.audioSec, greaterThan(5.0),
        reason: 'anchor 0 must land at the real first note, not in the intro');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
