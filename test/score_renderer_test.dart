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
