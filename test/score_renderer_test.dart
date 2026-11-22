import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:violin_practice_companion/services/score_renderer.dart';

/// Set SCORE_RENDER_OUT=<dir> to write the renders as WAVs for listening.
void main() {
  final sf = File('assets/engine/soundfonts/generaluser_gs.sf2').readAsBytesSync();
  final piece = MusicXmlParser()
      .parse(File('assets/library/lightly_row/score.musicxml').readAsStringSync());
  final renderer = ScoreRenderer(ByteData.sublistView(sf));

  /// RMS over 5 ms windows from [from] for [seconds].
  double rms(Float32List s, int from, int n) {
    var sum = 0.0;
    for (var i = from; i < from + n && i < s.length; i++) {
      sum += s[i] * s[i];
    }
    return math.sqrt(sum / n);
  }

  test('woodblock pre-roll, exact anchors, notes where the anchors say', () {
    const bpm = 100;
    final data = MidiGenerator.forTest().generate(piece, bpm);
    final sw = Stopwatch()..start();
    final r = renderer.render(piece, data, bpm);
    sw.stop();
    final rt = r.durationSeconds / (sw.elapsedMilliseconds / 1000);
    // ignore: avoid_print
    print('rendered ${r.durationSeconds.toStringAsFixed(1)}s in '
        '${sw.elapsedMilliseconds}ms (${rt.toStringAsFixed(0)}x real time); '
        'pre-roll ${r.prerollSeconds}s, '
        'peak ${r.samples.fold<double>(0, (m, v) => math.max(m, v.abs())).toStringAsFixed(3)}');

    final out = Platform.environment['SCORE_RENDER_OUT'];
    if (out != null) {
      File('$out/lightly_row_$bpm.wav').writeAsBytesSync(encodeWav(r));
    }

    // 4/4, no pickup: three bars of four quarters at 100 bpm.
    expect(r.clickSamples.length, 12);
    expect(r.prerollSeconds, closeTo(12 * 0.6, 1e-9));
    expect(r.anchors.first.audioSec, closeTo(r.prerollSeconds, 1e-9));
    expect(r.anchors.first.scoreMs, 0);
    expect(r.anchors.length, data.measureOnsetSeconds.length);

    // Each click is heard at its sample, and silence comes just before it.
    const win = 220; // 5 ms
    for (final c in r.clickSamples) {
      expect(rms(r.samples, c, win), greaterThan(0.01), reason: 'click at $c');
      if (c > win) {
        expect(rms(r.samples, c - win, win), lessThan(0.005),
            reason: 'quiet before click at $c');
      }
    }
    // The first note starts where the first anchor says, within a 32-sample
    // block, not earlier. The violin's attack is soft (it takes ~50 ms to
    // reach a quarter of its level), so compare against just before it.
    final first = (r.prerollSeconds * r.sampleRate).round();
    final before = rms(r.samples, first - 2 * win, win);
    expect(rms(r.samples, first + win, win), greaterThan(before * 4));
    expect(rms(r.samples, first + 10 * win, win), greaterThan(0.02));

  });

  test('the bank sounds the viola too (GM 41)', () {
    // The synth falls back to another preset when one is missing, so ask
    // the bank's preset headers (phdr: 38-byte records, preset and bank at
    // 20 and 22) rather than listening for silence.
    final bytes = ByteData.sublistView(sf);
    var at = -1;
    for (var i = 0; i + 4 < sf.length; i++) {
      if (sf[i] == 0x70 && sf[i + 1] == 0x68 && sf[i + 2] == 0x64 &&
          sf[i + 3] == 0x72) {
        at = i;
        break;
      }
    }
    expect(at, greaterThan(0), reason: 'no phdr chunk');
    final size = bytes.getUint32(at + 4, Endian.little);
    final presets = {
      for (var r = at + 8; r + 38 <= at + 8 + size; r += 38)
        (bytes.getUint16(r + 22, Endian.little),
            bytes.getUint16(r + 20, Endian.little)),
    };
    expect(presets, containsAll([(0, 40), (0, 41)]),
        reason: 'cut the bank with --keep 0:41 (README, "The soundfont")');
    const bpm = 100;
    final data = MidiGenerator.forTest().generate(piece, bpm);
    final r = ScoreRenderer(ByteData.sublistView(sf), program: 41)
        .render(piece, data, bpm);
    const win = 220;
    final first = (r.prerollSeconds * r.sampleRate).round();
    expect(rms(r.samples, first + 10 * win, win), greaterThan(0.02),
        reason: 'a bank cut without program 41 plays a viola part silently');
  });

  test('the bank sounds the recorder (GM 74), an octave above written', () {
    final bytes = ByteData.sublistView(sf);
    var at = -1;
    for (var i = 0; i + 4 < sf.length; i++) {
      if (sf[i] == 0x70 && sf[i + 1] == 0x68 && sf[i + 2] == 0x64 &&
          sf[i + 3] == 0x72) {
        at = i;
        break;
      }
    }
    final size = bytes.getUint32(at + 4, Endian.little);
    final presets = {
      for (var r = at + 8; r + 38 <= at + 8 + size; r += 38)
        (bytes.getUint16(r + 22, Endian.little),
            bytes.getUint16(r + 20, Endian.little)),
    };
    expect(presets, contains((0, 73)),
        reason: 'cut the bank with --keep 0:73 (README, "The soundfont")');
    const bpm = 100;
    final data =
        MidiGenerator.forTest(soundingSemitones: 12).generate(piece, bpm);
    final r = ScoreRenderer(ByteData.sublistView(sf), program: 73)
        .render(piece, data, bpm);
    const win = 220;
    final first = (r.prerollSeconds * r.sampleRate).round();
    expect(rms(r.samples, first + 10 * win, win), greaterThan(0.02),
        reason: 'a bank cut without program 73 plays a recorder part silently');
  });

  test('the bank sounds the mandolin (GS bank 16, program 25)', () {
    final bytes = ByteData.sublistView(sf);
    var at = -1;
    for (var i = 0; i + 4 < sf.length; i++) {
      if (sf[i] == 0x70 && sf[i + 1] == 0x68 && sf[i + 2] == 0x64 &&
          sf[i + 3] == 0x72) {
        at = i;
        break;
      }
    }
    final size = bytes.getUint32(at + 4, Endian.little);
    final presets = {
      for (var r = at + 8; r + 38 <= at + 8 + size; r += 38)
        (bytes.getUint16(r + 22, Endian.little),
            bytes.getUint16(r + 20, Endian.little)),
    };
    expect(presets, contains((16, 25)),
        reason: 'cut the bank with --keep 16:25 (README, "The soundfont")');
    const bpm = 100;
    final data = MidiGenerator.forTest().generate(piece, bpm);
    final r = ScoreRenderer(ByteData.sublistView(sf), bank: 16, program: 25)
        .render(piece, data, bpm);
    const win = 220;
    final first = (r.prerollSeconds * r.sampleRate).round();
    expect(rms(r.samples, first + 10 * win, win), greaterThan(0.02),
        reason: 'a bank cut without the mandolin plays its part silently');
    // The bank select reached the synth: without it, program 25 in bank 0
    // is missing from the cut bank and the synth falls back to another
    // preset, so the two renders would sound alike only if it were ignored.
    final fallback = ScoreRenderer(ByteData.sublistView(sf), program: 25)
        .render(piece, data, bpm);
    var diff = 0.0;
    for (var i = first; i < first + r.sampleRate; i++) {
      diff += (r.samples[i] - fallback.samples[i]).abs();
    }
    expect(diff, greaterThan(1.0), reason: 'bank 16 was not selected');
  });

  test('three tempo renders, timed', () {
    final total = Stopwatch()..start();
    for (final bpm in [67, 85, 107]) {
      final data = MidiGenerator.forTest().generate(piece, bpm);
      final r = renderer.render(piece, data, bpm);
      final out = Platform.environment['SCORE_RENDER_OUT'];
      if (out != null) {
        File('$out/lightly_row_$bpm.wav').writeAsBytesSync(encodeWav(r));
      }
    }
    // ignore: avoid_print
    print('three renders: ${total.elapsedMilliseconds}ms');
  });
}
