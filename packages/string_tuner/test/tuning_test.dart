import 'dart:math' as math;
import 'dart:typed_data';

import 'package:string_tuner/string_tuner.dart';
import 'package:test/test.dart';

List<double> hz(InstrumentTuning t) => [for (final s in t.strings) s.hz];
Matcher near(List<double> want) =>
    pairwiseCompare<double, double>(
        want, (a, b) => (a - b).abs() < 0.005, 'within 0.005 Hz of');

void main() {
  group('targets', () {
    test('violin at A = 440 is in pure fifths', () {
      expect(hz(InstrumentTuning.violin()), near([195.556, 293.333, 440, 660]));
    });
    test('violin at A = 442', () {
      expect(hz(InstrumentTuning.violin(a4: 442)), near([196.444, 294.667, 442, 663]));
    });
    test('mandolin is equal-tempered', () {
      expect(hz(InstrumentTuning.mandolin()), near([195.998, 293.665, 440, 659.255]));
    });
    test('cello anchors on its A3', () {
      expect(hz(InstrumentTuning.cello()), near([65.185, 97.778, 146.667, 220]));
    });
    test('names', () {
      expect(InstrumentTuning.viola().strings.map((s) => s.name), ['C3', 'G3', 'D4', 'A4']);
    });
    test('pure fifths refuses strings that are not in fifths', () {
      expect(
          () => InstrumentTuning(
              name: 'Guitar',
              openStrings: [40, 45, 50, 55, 59, 64],
              temperament: Temperament.pureFifths),
          throwsArgumentError);
    });
    test('violin G is about 4 cents under equal temperament', () {
      final g = InstrumentTuning.violin().strings.first;
      expect(centsBetween(g.hz, midiToHz(55)), closeTo(-3.91, 0.01));
    });
  });

  group('StringFollower', () {
    final violin = InstrumentTuning.violin();
    test('ignores a single stray reading', () {
      final f = StringFollower(violin);
      f.update(438);
      f.update(295); // one D-ish blip
      expect(f.update(441).string.name, 'A4');
    });
    test('by default ignores an 80 ms brush of the next string', () {
      // 80 ms of A inside a D gives about ten overlapping readings at a hop
      // of 512 samples at 48 kHz.
      final f = StringFollower(violin)..update(294);
      for (var i = 0; i < 10; i++) {
        f.update(440);
      }
      expect(f.update(294).string.name, 'D4');
    });
    test('switches after switchAfter readings in a row', () {
      final f = StringFollower(violin, switchAfter: 3)..update(440);
      f.update(294);
      f.update(294);
      final r = f.update(294);
      expect(r.string.name, 'D4');
      expect(r.cents, closeTo(3.93, 0.01)); // against pure-fifths D 293.33
    });
    test('pinned string wins', () {
      final f = StringFollower(violin)..pinned = violin.strings.first;
      expect(f.update(440).string.name, 'G3');
    });
  });

  group('PitchTracker', () {
    final yin = YinDetector(sampleRate: 48000, minHz: 130, maxHz: 1320);
    Float32List sine(int n) => Float32List.fromList(
        List.generate(n, (i) => 0.4 * math.sin(2 * math.pi * 440 * i / 48000)));

    test('one reading per hop once the first frame is full', () {
      final t = PitchTracker(yin);
      final r = t.addSamples(sine(2048 + 512 * 5 + 100));
      expect(r.length, 6);
      expect(r.first.endSample, 2048);
      expect(r.last.endSample, 2048 + 512 * 5);
    });

    test('chunk sizes do not change the readings', () {
      final all = sine(8000);
      final one = PitchTracker(yin).addSamples(all);
      final t = PitchTracker(yin);
      final pieces = <PitchReading>[];
      final rnd = math.Random(3);
      var i = 0;
      while (i < all.length) {
        final n = math.min(all.length - i, 1 + rnd.nextInt(900));
        pieces.addAll(t.addSamples(Float32List.sublistView(all, i, i + n)));
        i += n;
      }
      expect(pieces.map((p) => p.endSample), one.map((p) => p.endSample));
      expect(pieces.map((p) => p.pitch!.hz), one.map((p) => p.pitch!.hz));
      expect(one.last.pitch!.hz, closeTo(440, 0.2));
    });

    test('pcm16 round trip', () {
      final b = ByteData(6)
        ..setInt16(0, 16384, Endian.little)
        ..setInt16(2, -32768, Endian.little)
        ..setInt16(4, 0, Endian.little);
      expect(pcm16ToFloat32(b.buffer.asUint8List()), [0.5, -1.0, 0.0]);
    });
  });
}
