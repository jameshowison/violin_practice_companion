// Auto-alignment against a real recording of a tune with ties: Greg O'Leary's
// "Along the Road to Gundagai" from the Australian Traditional Music Archive
// (austradmusic.au/recordings/Along_the_Road_to_Gundagai.mp3 — the file the
// ABC's own `F:` line names), converted to assets/audio/gundagai/melody.wav:
//
//   afconvert -f WAVE -d LEI16@44100 -c 2 Along_the_Road_to_Gundagai.mp3 \
//     assets/audio/gundagai/melody.wav
//
// Gitignored like the other recordings (not ours to redistribute), so this
// skips where it's absent. The score is the app's own import of the same ABC
// (test/fixtures/gundagai.musicxml), so it exercises the converter's ties end
// to end: ties are folded into held notes by MidiGenerator, and the chroma
// reference the aligner matches against is built from those held notes.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/audio_energy_envelope.dart';
import 'package:violin_practice_companion/services/audio_score_auto_aligner.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/musicxml_normalizer.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';

void main() {
  final wavFile = File('assets/audio/gundagai/melody.wav');
  if (!wavFile.existsSync()) {
    test('gundagai auto-align (skipped: melody.wav not present)', () {});
    return;
  }

  final piece = MusicXmlParser().parse(MusicXmlNormalizer.toSoundingPitch(
      File('test/fixtures/gundagai.musicxml').readAsStringSync()));
  final untied = ParsedPiece(
    keySignature: piece.keySignature,
    keyFifths: piece.keyFifths,
    keyMode: piece.keyMode,
    divisions: piece.divisions,
    beatsPerMeasure: piece.beatsPerMeasure,
    beatType: piece.beatType,
    measures: [
      for (final m in piece.measures)
        m.copyWithNotes([
          for (final n in m.notes) n.copyWith(tieStart: false, tieStop: false)
        ]),
    ],
  );

  test('auto-alignment against the real Gundagai recording, ties held', () {
    final wavBytes = wavFile.readAsBytesSync();
    final aligner =
        AudioScoreAutoAligner(midiGenerator: MidiGenerator.forTest());
    final tiedResult = aligner.align(piece, wavBytes);
    final untiedResult = aligner.align(untied, wavBytes);

    final envelope =
        const AudioEnergyEnvelopeExtractor().extractFromWavBytes(wavBytes);
    final onsets =
        const AudioEnergyEnvelopeExtractor().detectOnsetTimes(envelope);
    double nearestOnset(double t) => onsets
        .map((o) => (o - t).abs())
        .reduce((a, b) => a < b ? a : b);

    for (final (label, r) in [('tied', tiedResult), ('untied', untiedResult)]) {
      final offsets = r.anchors.map((a) => nearestOnset(a.audioSec)).toList()
        ..sort();
      // ignore: avoid_print
      print('$label: bpm=${r.generationBpm} '
          'cost=${r.averageDtwCost.toStringAsFixed(4)} '
          'compressed=${r.hasCompressedAnchors} '
          'anchors=${r.anchors.length} '
          'span=${r.anchors.first.audioSec.toStringAsFixed(2)}–'
          '${r.anchors.last.audioSec.toStringAsFixed(2)}s '
          'medianToOnset=${offsets[offsets.length ~/ 2].toStringAsFixed(3)}s '
          'within100ms=${offsets.where((d) => d <= 0.1).length}/${offsets.length}');
    }

    final r = tiedResult;
    // One anchor per performed measure, in order, inside the recording.
    expect(r.anchors.length, piece.measures.length);
    for (var i = 1; i < r.anchors.length; i++) {
      expect(r.anchors[i].audioSec,
          greaterThanOrEqualTo(r.anchors[i - 1].audioSec));
    }
    expect(r.anchors.last.audioSec, lessThan(wavBytes.length / 44100 / 4));
    // No bar is squeezed or stretched far off the tempo around it. Before the
    // aligner knew about held barlines, bar 8 — held through by `G2-|G8-|G4`
    // — came out 0.16 s long against its neighbours' ~1.4 s. (Bar 1 is the
    // pickup, and the last anchor has no successor to measure against.)
    final lengths = [
      for (var i = 1; i + 1 < r.anchors.length; i++)
        r.anchors[i + 1].audioSec - r.anchors[i].audioSec,
    ];
    final median = ([...lengths]..sort())[lengths.length ~/ 2];
    for (var i = 0; i < lengths.length; i++) {
      expect(lengths[i], inInclusiveRange(median * 0.5, median * 2),
          reason: 'bar ${i + 2} lasts ${lengths[i].toStringAsFixed(2)}s '
              'against a median ${median.toStringAsFixed(2)}s');
    }
    // Holding the ties is the score the fiddler actually played, so it should
    // match the recording at least as well as re-striking every tied note.
    expect(r.averageDtwCost,
        lessThanOrEqualTo(untiedResult.averageDtwCost + 1e-9));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
