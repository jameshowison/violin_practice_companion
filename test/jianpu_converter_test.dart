import 'package:flutter_test/flutter_test.dart';

// Test the conversion logic directly without asset loading
// by extracting the core algorithm inline.

int? computeJianpuNumber(int midiNumber, List<int> scale) {
  final pc = midiNumber % 12;
  final idx = scale.indexOf(pc);
  if (idx >= 0) return idx + 1;
  // accidental — find nearest lower
  for (int i = scale.length - 1; i >= 0; i--) {
    if (scale[i] < pc) return i + 1;
  }
  return null;
}

int computeOctaveDots(int midiNumber, int referenceOctave) {
  final noteOctave = (midiNumber ~/ 12) - 1;
  return noteOctave - referenceOctave;
}

void main() {
  // D major scale: D=2, E=4, F#=6, G=7, A=9, B=11, C#=1
  const dMajorScale = [2, 4, 6, 7, 9, 11, 1];

  test('D4 is 1 in D major', () {
    expect(computeJianpuNumber(62, dMajorScale), 1); // D4 = MIDI 62, pc=2
  });

  test('E4 is 2 in D major', () {
    expect(computeJianpuNumber(64, dMajorScale), 2); // E4 = MIDI 64, pc=4
  });

  test('A4 is 5 in D major', () {
    expect(computeJianpuNumber(69, dMajorScale), 5); // A4 = MIDI 69, pc=9
  });

  test('D5 is 1 in D major', () {
    // D5 = MIDI 74, pc = 74 % 12 = 2, scale idx 0 → jianpu 1
    expect(computeJianpuNumber(74, dMajorScale), 1);
  });

  test('D5 octave dots = +1 relative to octave 4', () {
    expect(computeOctaveDots(74, 4), 1); // D5 octave = 5, ref = 4 → +1
  });

  test('D4 octave dots = 0 relative to octave 4', () {
    expect(computeOctaveDots(62, 4), 0);
  });

  test('D3 octave dots = -1 relative to octave 4', () {
    expect(computeOctaveDots(50, 4), -1); // D3 = MIDI 50, octave=(50/12)-1=3
  });

  // A major scale: A=9, B=11, C#=1, D=2, E=4, F#=6, G#=8
  const aMajorScale = [9, 11, 1, 2, 4, 6, 8];

  test('A4 is 1 in A major', () {
    expect(computeJianpuNumber(69, aMajorScale), 1);
  });

  test('E5 is 5 in A major', () {
    expect(computeJianpuNumber(76, aMajorScale), 5); // E5=MIDI76, pc=4, idx=4
  });
}
