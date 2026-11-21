import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pitch_tuner/pitch_tuner.dart';
import 'package:test/test.dart';

double off(double hz, double cents) => hz * math.pow(2, cents / 1200);

void main() {
  group('chromatic', () {
    final c = InstrumentTuning.chromatic();

    test('every semitone from C2 to C7, equal-tempered', () {
      expect(c.kind, TargetKind.chromatic);
      expect(c.strings.length, 61);
      expect(c.strings.first.name, 'C2');
      expect(c.strings.last.name, 'C7');
      expect(c.strings.firstWhere((s) => s.name == 'A4').hz, closeTo(440, 1e-9));
      expect(c.strings.firstWhere((s) => s.name == 'G3').hz, closeTo(195.998, 0.001));
    });

    test('nearest is the nearest semitone, either side of the half-way', () {
      expect(c.nearest(off(440, 49)).name, 'A4');
      expect(c.nearest(off(440, 51)).name, 'B♭4');
      expect(c.nearest(off(440, -51)).name, 'A♭4');
      expect(c.nearest(10).name, 'C2', reason: 'clamped to the range');
      expect(c.nearest(20000).name, 'C7');
    });

    test('nearest agrees with a search of every target', () {
      for (var hz = 60.0; hz < 2000; hz *= 1.013) {
        final want = c.strings.reduce((a, b) =>
            centsBetween(hz, a.hz).abs() <= centsBetween(hz, b.hz).abs() ? a : b);
        expect(c.nearest(hz).midi, want.midi, reason: '$hz Hz');
      }
    });

    test('follows the reference A, and a narrower range narrows detection', () {
      final flute = InstrumentTuning.chromatic(a4: 442, lowest: 60, highest: 96);
      expect(flute.strings.firstWhere((s) => s.name == 'A4').hz, 442);
      expect(flute.detectionRange.minHz, closeTo(midiToHz(60, a4: 442) / 1.5, 1e-9));
      expect(() => InstrumentTuning.chromatic(lowest: 70, highest: 60), throwsArgumentError);
    });

    test('the model reads a played note against the nearest semitone', () {
      final m = TunerModel(InstrumentTuning.chromatic(lowest: 48, highest: 84));
      for (var i = 0; i < 60; i++) {
        m.add(TunerFrame(Duration(microseconds: (i * 512 * 1e6 / 48000).round()),
            PitchEstimate(hz: off(415.305, 12), clarity: 0.97, rms: 0.05)));
      }
      expect(m.reading!.string.name, 'A♭4');
      expect(m.reading!.cents, closeTo(12, 0.01));
    });
  });

  test('one note', () {
    final n = InstrumentTuning.note(62, a4: 442);
    expect(n.kind, TargetKind.note);
    expect(n.strings.single.name, 'D4');
    expect(n.strings.single.hz, closeTo(midiToHz(62, a4: 442), 1e-9));
    expect(n.nearest(1000).name, 'D4');
    expect(InstrumentTuning.violin().kind, TargetKind.openStrings);
  });

  group('transposition', () {
    final c = InstrumentTuning.chromatic();
    TunedString at(String name) => c.strings.firstWhere((s) => s.name == name);

    test('shows the written note for what sounds', () {
      expect(Transposition.bFlat.writtenName(at('C4')), 'D4');
      expect(Transposition.bFlat.writtenName(at('B♭3')), 'C4');
      expect(Transposition.eFlatAlto.writtenName(at('E♭4')), 'C5');
      expect(Transposition.f.writtenName(at('F3')), 'C4');
      expect(Transposition.bFlatTenor.writtenName(at('B♭2')), 'C4');
      expect(Transposition.octaveDown.writtenName(at('E2')), 'E3', reason: 'a guitar\'s low E');
      expect(Transposition.concert.writtenName(at('A4')), 'A4');
    });

    test('written and sounding are inverses', () {
      for (final t in const [Transposition.bFlat, Transposition.eFlatHigh, Transposition.octaveUp]) {
        for (var m = 40; m < 90; m++) {
          expect(t.sounding(t.written(m)), m);
        }
      }
    });
  });

  group('drone', () {
    test('a whole number of cycles: the loop has no seam', () {
      for (final hz in [130.81, 195.556, 440.0, 659.255, 1046.5]) {
        final d = DroneTone.render(hz);
        expect(centsBetween(d.hz, hz).abs(), lessThan(0.1), reason: '$hz');
        final s = d.samples;
        // The step from the last sample back to the first is no bigger than
        // the steps inside the buffer.
        var maxStep = 0.0;
        for (var i = 1; i < s.length; i++) {
          maxStep = math.max(maxStep, (s[i] - s[i - 1]).abs());
        }
        expect((s.first - s.last).abs(), lessThanOrEqualTo(maxStep * 1.01), reason: '$hz');
        expect(s.first, closeTo(0, 1e-6), reason: 'starts at a zero crossing');
      }
    });

    test('reads back at its pitch through the tracker', () {
      final d = DroneTone.render(195.556);
      final loops = Float32List(d.samples.length * 2)
        ..setAll(0, d.samples)
        ..setAll(d.samples.length, d.samples);
      final tracker = PitchTracker(YinDetector(sampleRate: 48000, minHz: 120, maxHz: 1400));
      final readings = [for (final r in tracker.addSamples(loops)) if (r.pitch != null) r.pitch!.hz];
      expect(readings, isNotEmpty);
      for (final hz in readings) {
        expect(centsBetween(hz, 195.556).abs(), lessThan(1));
      }
    });

    test('peaks at the amplitude asked for', () {
      final d = DroneTone.render(440, amplitude: 0.5);
      expect(d.samples.map((v) => v.abs()).reduce(math.max), closeTo(0.5, 1e-6));
    });

    test('is a 16-bit mono WAV', () {
      final d = DroneTone.render(440, seconds: 0.5);
      final w = ByteData.sublistView(d.toWav());
      expect(String.fromCharCodes(d.toWav().sublist(0, 4)), 'RIFF');
      expect(w.getUint16(22, Endian.little), 1);
      expect(w.getUint32(24, Endian.little), 48000);
      expect(w.getUint16(34, Endian.little), 16);
      expect(w.getUint32(40, Endian.little), d.samples.length * 2);
    });
  });
}
