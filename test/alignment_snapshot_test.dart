// The safety net for moving the alignment code into a library
// (docs/libraries-migration.md), as migration_snapshot_test is for MusicXML.
//
// A few bundled scores are played by a small additive synth, with a lead-in and
// a tempo that drifts, and aligned with and without a content window. The
// anchors, tempo, cost and compression flag are compared, to full double
// precision, with test/fixtures/alignment_snapshot.json. A move must leave
// them identical; a real change to the aligner refreshes them:
//
//   UPDATE_SNAPSHOT=1 flutter test test/alignment_snapshot_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:audio_decoder/audio_decoder.dart';
import 'package:score_sync/score_sync.dart';
import 'package:violin_practice_companion/services/piece_aligner.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';

import 'support/bundled_scores.dart';

const _goldenPath = 'test/fixtures/alignment_snapshot.json';
const _sampleRate = 16000.0;
const _leadIn = 0.75;
const _pieces = ['happy_farmer', 'lightly_row', 'long_long_ago', 'old_joe_clark'];

/// Score seconds (at 60 bpm) to performance seconds: a lead-in, a tempo a
/// little under the written one, and a gentle ritardando.
double _performed(double t) => _leadIn + 0.9 * t + 0.002 * t * t;

PcmAudio _synth(MidiData midi) {
  final end = _performed(midi.totalDurationSeconds) + 1.0;
  final samples = Float64List((end * _sampleRate).ceil());
  for (final n in midi.notes) {
    final start = (_performed(n.onsetSeconds) * _sampleRate).round();
    final stop = (_performed(n.offsetSeconds) * _sampleRate).round();
    final hz = 440.0 * math.pow(2, (n.midiNote - 69) / 12);
    for (var i = start; i < stop && i < samples.length; i++) {
      final t = (i - start) / _sampleRate;
      final env = math.exp(-2.5 * t) * math.min(1, t * 200);
      var s = 0.0;
      for (var h = 1; h <= 4; h++) {
        s += math.sin(2 * math.pi * hz * h * t) / (h * h);
      }
      samples[i] += 0.3 * env * s;
    }
  }
  return PcmAudio(samples, _sampleRate);
}

String _result(AutoAlignmentResult r) => [
      'bpm ${r.generationBpm}',
      'cost ${r.averageDtwCost}',
      'compressed ${r.hasCompressedAnchors}',
      for (final a in r.anchors) '${a.scoreMs} ${a.audioSec}',
    ].join('\n');

void main() {
  test('alignInBackground gives exactly what aligning here gives', () async {
    final generator = MidiGenerator.forTest();
    final aligner = AudioScoreAutoAligner(midiGenerator: generator);
    final piece = MusicXmlParser()
        .parse(File(scorePath('lightly_row')).readAsStringSync());
    final audio = _synth(generator.generate(piece, 60));
    final here = aligner.alignPcm(piece, audio, contentStartSeconds: _leadIn);
    final there = await aligner.alignInBackground(piece,
        pcm: audio, contentStartSeconds: _leadIn);
    expect(_result(there), _result(here));
  });

  test('bundled scores align exactly as the snapshot says', () {
    final generator = MidiGenerator.forTest();
    final aligner = AudioScoreAutoAligner(midiGenerator: generator);
    final actual = <String, String>{};
    // A few, not all: the whole library takes 90 s, most of it the longest
    // scores' DTW.
    for (final f in bundledScoreFiles().where((f) => _pieces.any(f.path.contains))) {
      final piece = MusicXmlParser().parse(f.readAsStringSync());
      final audio = _synth(generator.generate(piece, 60));
      actual['${f.path} open'] = _result(aligner.alignPcm(piece, audio));
      actual['${f.path} window'] = _result(aligner.alignPcm(piece, audio,
          contentStartSeconds: _leadIn,
          contentEndSeconds: audio.durationSeconds - 0.5));
    }

    final golden = File(_goldenPath);
    if (Platform.environment['UPDATE_SNAPSHOT'] == '1' || !golden.existsSync()) {
      final sorted = Map.fromEntries(
          actual.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
      golden.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(sorted)}\n');
      return;
    }
    final expected =
        (json.decode(golden.readAsStringSync()) as Map).cast<String, String>();
    for (final k in {...expected.keys, ...actual.keys}) {
      expect(actual[k], expected[k], reason: k);
    }
  });
}
