// Times YinDetector per frame, compiled: dart compile exe tool/bench.dart -o /tmp/bench && /tmp/bench
// ignore_for_file: avoid_print
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:string_tuner/string_tuner.dart';

void main() {
  const sr = 48000.0;
  final f = Float32List.fromList(List.generate(2048, (i) {
    var v = 0.0;
    for (var k = 1; k <= 8; k++) { v += math.sin(2 * math.pi * 440 * k * i / sr) / k; }
    return v * 0.2;
  }));
  final r = InstrumentTuning.violin().detectionRange;
  for (final (label, yin) in [
    ('violin range ${r.minHz.toStringAsFixed(0)}–${r.maxHz.toStringAsFixed(0)} Hz', YinDetector(sampleRate: sr, minHz: r.minHz, maxHz: r.maxHz)),
    ('full range, 47 Hz up (like pitch_detector_dart)', YinDetector(sampleRate: sr, minHz: 47, maxHz: 20000)),
  ]) {
    for (var i = 0; i < 100; i++) { yin.detect(f); }
    final sw = Stopwatch()..start();
    const runs = 2000;
    for (var i = 0; i < runs; i++) { yin.detect(f); }
    print('$label: ${(sw.elapsedMicroseconds / runs).toStringAsFixed(0)} µs per 2048-sample frame');
  }
}
