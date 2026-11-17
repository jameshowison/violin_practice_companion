// Regression test for [DtwAligner.maxReferenceStride]: a teacher's practice
// video whose first twelve bars are all the same, a rest then an A.
//
// The recording talks for 12.5 s, then plays the twelve As about 1.5 s apart
// (12.6-30.4 s). Without a stride cap, the open boundary treated most of them
// as intro and crushed bars 1-7 into about a second: bar 1 at 24.9 s, bars
// 3-7 taking no time at all. Ground truth is by ear and by the plucks'
// onsets: each A is on beat 2, so bar 1 starts ~0.74 s before the first, at
// ~12.55 s.
//
// The recording is not ours, so it lives in the private companion checkout
// and this skips without it.
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/audio_score_auto_aligner.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/musicxml_normalizer.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

import 'support/restricted_fixtures.dart';

void main() {
  test('twelve identical opening bars land one per played note',
      skip: skipUnlessRestricted(kHanukkahTeacherWav) ??
          skipUnlessRestricted(kHanukkahScore), () {
    final piece = MusicXmlParser().parse(
        MusicXmlNormalizer.toSoundingPitch(readRestricted(kHanukkahScore)));
    final result = AudioScoreAutoAligner(midiGenerator: MidiGenerator.forTest())
        .align(piece, restrictedFile(kHanukkahTeacherWav)!.readAsBytesSync());
    final bar = [for (final a in result.anchors) a.audioSec];

    expect(bar[0], closeTo(12.55, 0.4), reason: 'bar 1 starts at the first A');
    for (var i = 0; i < 12; i++) {
      final length = bar[i + 1] - bar[i];
      expect(length, inInclusiveRange(1.2, 1.8),
          reason: 'bar ${i + 1} is ${length.toStringAsFixed(2)} s; '
              'the steady tempo is ~1.48 s a bar');
    }
    // After the page-turn pause and the talking in bars 43-44, bar 45 is
    // back on its notes.
    expect(bar[44], closeTo(88.4, 0.4));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
