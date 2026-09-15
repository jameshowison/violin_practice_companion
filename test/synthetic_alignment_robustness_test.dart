// Synthetic robustness coverage for the alignment pipeline.
//
// Every other real-recording alignment test in this repo depends on a
// gitignored asset (`assets/audio/`, `docs/photos_no_share/`), so on a fresh
// clone none of them run. This one synthesizes its recordings from the score
// itself, so it always runs, and its ground truth is exact by construction
// rather than timed by ear.
//
// It exists because `DtwAligner.skipPenaltyPerFrame` is a single tuned scalar
// and the two real recordings that pin its safe window pin one edge each —
// n=2 is not much to stand a constant on. Sweeping these conditions puts the
// safe window at 0.13-0.30 (worst anchor-0 error 0.29s at 0.10, 5.0s at 0.45,
// under 0.06s in between), which agrees with the 0.13-0.23 the real
// recordings give. See docs/audio-sync-dtw-interior-gaps.md.
//
// What it does NOT cover: the notes are rendered from the same MidiGenerator
// that builds the DTW reference, so audio and reference share a pitch model.
// Timbral mismatch between a real instrument and the symbolic reference —
// the thing that actually made the Galopede recording hard — is out of reach
// here and still rests on the real fixtures.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/audio_score_auto_aligner.dart';
import 'package:violin_practice_companion/services/dtw_align.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/musicxml_normalizer.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';
import 'package:wav/wav.dart';

const _rate = 44100;

double _hzOf(int midiNote) => 440.0 * math.pow(2, (midiNote - 69) / 12.0);

/// Renders [notes] as a harmonic-rich tone per note (a plucked/bowed string
/// has strong partials), then mixes in a stationary low hum and broadband
/// noise at the requested levels relative to the notes.
Float64List _render(
  List<({int midiNote, double onsetSeconds, double offsetSeconds})> notes,
  double totalSeconds, {
  required double humLevel,
  required double noiseLevel,
  double detuneCents = 0,
  double noteLevel = 0.30,
  int seed = 7,
}) {
  final n = (totalSeconds * _rate).round();
  final out = Float64List(n);
  for (final note in notes) {
    final detune = math.pow(2, detuneCents / 1200.0).toDouble();
    final f0 = _hzOf(note.midiNote) * detune;
    final start = (note.onsetSeconds * _rate).round().clamp(0, n);
    final end = (note.offsetSeconds * _rate).round().clamp(0, n);
    for (var i = start; i < end; i++) {
      final t = (i - start) / _rate;
      // Decaying envelope with a fast attack — closer to a real string than
      // a rectangular gate, and it gives the onset detector something.
      final env = math.exp(-2.2 * t) * (1 - math.exp(-t * 400));
      var v = 0.0;
      for (var h = 1; h <= 5; h++) {
        v += math.sin(2 * math.pi * f0 * h * i / _rate) / h;
      }
      out[i] += noteLevel * env * v;
    }
  }
  final rnd = math.Random(seed);
  // Hum with partials reaching WELL INTO the melody band (up to ~660 Hz), not
  // just the sub-180 Hz region the band floor already removes for free. A
  // hum confined below the floor tests nothing.
  for (var i = 0; i < n; i++) {
    var h = 0.0;
    for (var k = 1; k <= 11; k++) {
      h += math.sin(2 * math.pi * 60 * k * i / _rate) / math.sqrt(k);
    }
    out[i] += humLevel * h + noiseLevel * (rnd.nextDouble() * 2 - 1);
  }
  return out;
}

typedef Note = ({int midiNote, double onsetSeconds, double offsetSeconds});

/// A synthetic recording of [piece] at [bpm], preceded by an intro and
/// followed by an outro of the requested kind, plus hum/noise.
/// Returns the WAV bytes and the exact audio second each performance measure
/// starts at.
(Uint8List, List<double>) _synthesize(
  ParsedPiece piece,
  MidiGenerator gen, {
  required int bpm,
  required String intro,
  required String outro,
  required double introSeconds,
  required double humLevel,
  required double noiseLevel,
  required double jitterSeconds,
  required double noteLevel,
}) {
  final data = gen.generate(piece, bpm);
  final notes = <Note>[];
  final shift = introSeconds;

  // Intro.
  if (intro == 'quote') {
    // Restates the opening phrase — the Lightly Row hard case.
    for (final note in data.notes) {
      if (note.onsetSeconds > introSeconds * 0.8) break;
      notes.add((
        midiNote: note.midiNote,
        onsetSeconds: note.onsetSeconds,
        offsetSeconds: note.offsetSeconds,
      ));
    }
  } else if (intro == 'unrelated') {
    // A pitch the piece never uses, held — a spoken/tuning-up stand-in.
    for (var t = 0.0; t < introSeconds - 0.3; t += 0.5) {
      notes.add((midiNote: 61, onsetSeconds: t, offsetSeconds: t + 0.45));
    }
  } // 'silence' adds nothing

  // Per-note timing jitter plus a slow tempo drift, so the performance does
  // not line up frame-for-frame with a reference generated at a constant
  // tempo. Without this the cost surface has far more contrast than any real
  // recording and no penalty can be distinguished from another.
  final jrnd = math.Random(99);
  final span = data.totalDurationSeconds;
  double warp(double t) {
    final drift = 0.05 * math.sin(2 * math.pi * t / math.max(span, 1e-9));
    return t * (1 + drift);
  }
  for (final note in data.notes) {
    final jitter = (jrnd.nextDouble() - 0.5) * 2 * jitterSeconds;
    notes.add((
      midiNote: note.midiNote,
      onsetSeconds: warp(note.onsetSeconds) + shift + jitter,
      offsetSeconds: warp(note.offsetSeconds) + shift + jitter,
    ));
  }

  var total = data.totalDurationSeconds + shift;
  if (outro == 'quote') {
    // Loops back to the top — the Galopede hard case.
    final loopStart = total + 0.4;
    for (final note in data.notes) {
      if (note.onsetSeconds > 8.0) break;
      notes.add((
        midiNote: note.midiNote,
        onsetSeconds: note.onsetSeconds + loopStart,
        offsetSeconds: note.offsetSeconds + loopStart,
      ));
    }
    total = loopStart + 8.5;
  } else if (outro == 'silence') {
    total += 4.0;
  }

  final samples = _render(notes, total,
      humLevel: humLevel,
      noiseLevel: noiseLevel,
      detuneCents: 18,
      noteLevel: noteLevel);
  final truth =
      data.measureOnsetSeconds.map((s) => s + shift).toList(growable: false);
  return (Wav([samples], _rate).write(), truth);
}

void main() {
  test('anchor 0 lands on the first note across intro, outro and SNR '
      'conditions', () {
    final xml = File('assets/striped/lightly_row_musescore.xml');
    if (!xml.existsSync()) return;
    final piece = MusicXmlParser()
        .parse(MusicXmlNormalizer.toSoundingPitch(xml.readAsStringSync()));
    final gen = MidiGenerator.forTest();

    // The shipped default only; the full sweep lives in the doc.
    final penalties = [const DtwAligner().skipPenaltyPerFrame];
    final conditions = <({
      String name,
      String intro,
      String outro,
      double introSeconds,
      double hum,
      double noise,
      double jitter,
      double noteLevel,
      int bpm,
    })>[
      (name: 'clean, silent intro', intro: 'silence', outro: 'silence', introSeconds: 3.0, hum: 0.0, noise: 0.0005, jitter: 0.06, noteLevel: 0.30, bpm: 90),
      (name: 'clean, no intro', intro: 'silence', outro: 'silence', introSeconds: 0.0, hum: 0.0, noise: 0.0005, jitter: 0.06, noteLevel: 0.30, bpm: 90),
      (name: 'unrelated intro', intro: 'unrelated', outro: 'silence', introSeconds: 5.0, hum: 0.0, noise: 0.0005, jitter: 0.06, noteLevel: 0.30, bpm: 90),
      (name: 'INTRO QUOTES TUNE', intro: 'quote', outro: 'silence', introSeconds: 6.0, hum: 0.0, noise: 0.0005, jitter: 0.06, noteLevel: 0.30, bpm: 90),
      (name: 'OUTRO QUOTES TUNE', intro: 'silence', outro: 'quote', introSeconds: 3.0, hum: 0.0, noise: 0.0005, jitter: 0.06, noteLevel: 0.30, bpm: 90),
      (name: 'loud hum', intro: 'silence', outro: 'silence', introSeconds: 3.0, hum: 0.25, noise: 0.002, jitter: 0.06, noteLevel: 0.30, bpm: 90),
      (name: 'loud hum + quote intro', intro: 'quote', outro: 'silence', introSeconds: 6.0, hum: 0.25, noise: 0.002, jitter: 0.06, noteLevel: 0.30, bpm: 90),
      (name: 'loud hum + quote outro', intro: 'silence', outro: 'quote', introSeconds: 3.0, hum: 0.25, noise: 0.002, jitter: 0.06, noteLevel: 0.30, bpm: 90),
      (name: 'very noisy', intro: 'silence', outro: 'silence', introSeconds: 3.0, hum: 0.10, noise: 0.02, jitter: 0.06, noteLevel: 0.30, bpm: 90),
      (name: 'fast tempo', intro: 'silence', outro: 'quote', introSeconds: 3.0, hum: 0.05, noise: 0.001, jitter: 0.06, noteLevel: 0.30, bpm: 150),
      (name: 'QUIET notes vs hum', intro: 'silence', outro: 'silence', introSeconds: 3.0, hum: 0.30, noise: 0.004, jitter: 0.06, noteLevel: 0.015, bpm: 90),
      (name: 'QUIET + quote outro', intro: 'silence', outro: 'quote', introSeconds: 3.0, hum: 0.30, noise: 0.004, jitter: 0.06, noteLevel: 0.015, bpm: 90),
      (name: 'QUIET + quote intro', intro: 'quote', outro: 'silence', introSeconds: 6.0, hum: 0.30, noise: 0.004, jitter: 0.06, noteLevel: 0.015, bpm: 90),
    ];

    // ignore: avoid_print
    print('ANCHOR 0 absolute error in seconds, per condition x penalty');
    // ignore: avoid_print
    print('${'condition'.padRight(24)}${penalties.map((p) => p.toStringAsFixed(3).padLeft(8)).join()}');
    final perPenaltyWorst = List<double>.filled(penalties.length, 0);
    for (final c in conditions) {
      final (bytes, truth) = _synthesize(piece, gen,
          bpm: c.bpm,
          intro: c.intro,
          outro: c.outro,
          introSeconds: c.introSeconds,
          humLevel: c.hum,
          noiseLevel: c.noise,
          jitterSeconds: c.jitter,
          noteLevel: c.noteLevel);
      final row = StringBuffer(c.name.padRight(24));
      for (var pi = 0; pi < penalties.length; pi++) {
        final r = AudioScoreAutoAligner(
          midiGenerator: gen,
          dtw: DtwAligner(skipPenaltyPerFrame: penalties[pi]),
        ).align(piece, bytes);
        // Anchor 0's error is the thing that moved on the real recordings:
        // a first anchor dragged into the intro is a big error on ONE anchor,
        // which a 16-anchor mean hides almost completely.
        final n = math.min(r.anchors.length, truth.length);
        final a0Err =
            n == 0 ? 99.0 : (r.anchors[0].audioSec - truth[0]).abs();
        if (a0Err > perPenaltyWorst[pi]) perPenaltyWorst[pi] = a0Err;
        row.write(a0Err.toStringAsFixed(2).padLeft(8));
      }
      // ignore: avoid_print
      print(row.toString());
    }
    // ignore: avoid_print
    print('${'WORST CASE'.padRight(24)}${perPenaltyWorst.map((v) => v.toStringAsFixed(2).padLeft(8)).join()}');

    // 0.25s is about a quarter note at these tempos — comfortably above the
    // ~0.05s the default achieves, and far below the 0.29s/5.0s that a
    // mis-set penalty produces on these same conditions.
    expect(perPenaltyWorst.first, lessThan(0.25),
        reason: 'anchor 0 must land near the first note in every condition; '
            'a large error here means the skip penalty has drifted out of '
            'its safe window');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
