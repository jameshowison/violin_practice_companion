// Manual proof-out for the on-device auto-alignment pipeline, run once
// against the real Salt Creek recording before any of this gets wired into
// the app (see the audio-score-auto-align plan's "prove out the algorithm
// first" verification step).
//
// The score below is a hand transcription of docs/salt_creek.abc (verified
// against that file when written) — not derived from the app's ABC importer,
// so this test only exercises the alignment pipeline, not ABC parsing.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/audio_energy_envelope.dart';
import 'package:violin_practice_companion/services/audio_score_auto_aligner.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';

// Pitch classes under K:Amix (2 sharps: F#, C#), single canonical octave —
// octave never matters for chroma (pitch-class only).
const int _a = 69, _b = 71, _cSharp = 61, _d = 62, _e = 64, _fSharp = 66, _g = 67;

NoteEvent _n(int midi, NoteValue v) => NoteEvent(
      pitch: 'X',
      midiNumber: midi,
      octave: 4,
      noteValue: v,
      dotted: false,
      isRest: false,
    );

void main() {
  final wavFile = File('assets/audio/salt_creek/melody.wav');
  if (!wavFile.existsSync()) {
    // Author-supplied asset, gitignored — skip gracefully where absent.
    test('salt creek auto-align (skipped: melody.wav not present)', () {});
    return;
  }

  test('auto-alignment against the real Salt Creek melody recording', () {
    // |: A2 AA A2 AA | BA Bc "D"d4 | "G"BA GA BA GA | BA GF E4 |
    // "A"A2 AA A2 AA | BA Bc d4 | "G"e2 ef gf ed | "Em"cA Bc A4 :|
    final m1 = [_n(_a, NoteValue.quarter), _n(_a, NoteValue.eighth), _n(_a, NoteValue.eighth), _n(_a, NoteValue.quarter), _n(_a, NoteValue.eighth), _n(_a, NoteValue.eighth)];
    final m2 = [_n(_b, NoteValue.eighth), _n(_a, NoteValue.eighth), _n(_b, NoteValue.eighth), _n(_cSharp, NoteValue.eighth), _n(_d, NoteValue.half)];
    final m3 = [_n(_b, NoteValue.eighth), _n(_a, NoteValue.eighth), _n(_g, NoteValue.eighth), _n(_a, NoteValue.eighth), _n(_b, NoteValue.eighth), _n(_a, NoteValue.eighth), _n(_g, NoteValue.eighth), _n(_a, NoteValue.eighth)];
    final m4 = [_n(_b, NoteValue.eighth), _n(_a, NoteValue.eighth), _n(_g, NoteValue.eighth), _n(_fSharp, NoteValue.eighth), _n(_e, NoteValue.half)];
    final m7 = [_n(_e, NoteValue.quarter), _n(_e, NoteValue.eighth), _n(_fSharp, NoteValue.eighth), _n(_g, NoteValue.eighth), _n(_fSharp, NoteValue.eighth), _n(_e, NoteValue.eighth), _n(_d, NoteValue.eighth)];
    final m8 = [_n(_cSharp, NoteValue.eighth), _n(_a, NoteValue.eighth), _n(_b, NoteValue.eighth), _n(_cSharp, NoteValue.eighth), _n(_a, NoteValue.half)];

    // |: "A"a2 aa a2 aa | ab ag e4 | "G"g2 gg g2 gg | ga ge d4 |
    // "A"a2 aa a2 aa | ab ag e4 | "G"e2 ef gf ed | "Em"cA Bc A4 :|
    final m9 = m1; // same pitch classes, an octave up in the ABC (irrelevant to chroma)
    final m10 = [_n(_a, NoteValue.eighth), _n(_b, NoteValue.eighth), _n(_a, NoteValue.eighth), _n(_g, NoteValue.eighth), _n(_e, NoteValue.half)];
    final m11 = [_n(_g, NoteValue.quarter), _n(_g, NoteValue.eighth), _n(_g, NoteValue.eighth), _n(_g, NoteValue.quarter), _n(_g, NoteValue.eighth), _n(_g, NoteValue.eighth)];
    final m12 = [_n(_g, NoteValue.eighth), _n(_a, NoteValue.eighth), _n(_g, NoteValue.eighth), _n(_e, NoteValue.eighth), _n(_d, NoteValue.half)];

    final measures = <Measure>[
      Measure(number: 1, notes: m1, repeatStart: true),
      Measure(number: 2, notes: m2),
      Measure(number: 3, notes: m3),
      Measure(number: 4, notes: m4),
      Measure(number: 5, notes: m1),
      Measure(number: 6, notes: m2),
      Measure(number: 7, notes: m7),
      Measure(number: 8, notes: m8, repeatEnd: true),
      Measure(number: 9, notes: m9, repeatStart: true),
      Measure(number: 10, notes: m10),
      Measure(number: 11, notes: m11),
      Measure(number: 12, notes: m12),
      Measure(number: 13, notes: m9),
      Measure(number: 14, notes: m10),
      Measure(number: 15, notes: m7),
      Measure(number: 16, notes: m8, repeatEnd: true),
    ];
    final piece = ParsedPiece(
      keySignature: 'A',
      keyFifths: 2,
      keyMode: KeyMode.mixolydian,
      measures: measures,
      beatsPerMeasure: 2,
      beatType: 2,
    );

    final wavBytes = wavFile.readAsBytesSync();
    final aligner = AudioScoreAutoAligner(midiGenerator: MidiGenerator.forTest());
    final result = aligner.align(piece, wavBytes);

    // ignore: avoid_print
    print('generationBpm=${result.generationBpm} '
        'averageDtwCost=${result.averageDtwCost.toStringAsFixed(4)}');
    for (var i = 0; i < result.anchors.length; i++) {
      final a = result.anchors[i];
      // ignore: avoid_print
      print('measure ${i + 1}: scoreMs=${a.scoreMs.toStringAsFixed(0)} '
          'audioSec=${a.audioSec.toStringAsFixed(3)}');
    }

    // 32 performed measures (AABB, 8+8 notated measures each repeated once).
    // One anchor per performed measure — see docs/audio-sync-dtw-anchor-
    // compression.md for the anchor-compression signature this pipeline can
    // hit on chroma-ambiguous measures; it's now only flagged (via
    // result.hasCompressedAnchors), not discarded, so the count should be
    // exactly 32 regardless.
    expect(result.anchors.length, 32);
    for (var i = 1; i < result.anchors.length; i++) {
      expect(result.anchors[i].audioSec,
          greaterThanOrEqualTo(result.anchors[i - 1].audioSec));
    }
    expect(result.anchors.first.audioSec, lessThan(2.0));
    expect(result.anchors.last.audioSec, lessThan(wavBytes.length / 44100 / 2));

    // Objective cross-check, since nothing in this pipeline can "listen":
    // does each anchor actually land near a real note attack in the
    // recording? Detect onsets independently (simple energy-rise peak
    // picking, no chroma/score involved) and measure each anchor's distance
    // to the nearest one.
    final envelope = const AudioEnergyEnvelopeExtractor().extractFromWavBytes(wavBytes);
    final onsets = const AudioEnergyEnvelopeExtractor().detectOnsetTimes(envelope);
    // ignore: avoid_print
    print('detected ${onsets.length} onsets');

    final offsets = result.anchors.map((a) {
      var best = double.infinity;
      for (final o in onsets) {
        final d = (o - a.audioSec).abs();
        if (d < best) best = d;
      }
      return best;
    }).toList();
    for (var i = 0; i < offsets.length; i++) {
      if (offsets[i] > 0.1) {
        // ignore: avoid_print
        print('measure ${i + 1}: ${offsets[i].toStringAsFixed(3)}s from nearest onset');
      }
    }
    final sorted = [...offsets]..sort();
    final median = sorted[sorted.length ~/ 2];
    final mean = offsets.reduce((a, b) => a + b) / offsets.length;
    final within100ms = offsets.where((d) => d <= 0.1).length;
    // ignore: avoid_print
    print('anchor-to-nearest-onset: median=${median.toStringAsFixed(3)}s '
        'mean=${mean.toStringAsFixed(3)}s '
        'within100ms=$within100ms/${offsets.length}');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
