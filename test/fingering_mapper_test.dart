import 'package:flutter_test/flutter_test.dart';

// Test fingering logic inline without asset loading.
// Mirrors the algorithm in fingering_mapper.dart.

typedef FingeringEntry = ({String string, String finger, Map<String, String>? alt});

({String string, String finger}) resolveFingeringEntry(
    FingeringEntry entry, String preference) {
  final alt = entry.alt;
  if (alt != null) {
    final altFinger = alt['finger']!;
    final altString = alt['string']!;
    if (preference == 'open' && altFinger == '0') {
      return (string: altString, finger: altFinger);
    }
    if (preference == 'fingered' && entry.finger == '0') {
      return (string: altString, finger: altFinger);
    }
  }
  return (string: entry.string, finger: entry.finger);
}

void main() {
  // G4 = MIDI 62: G-string finger 4, alt D-string open (finger "0")
  final g4Entry = (
    string: 'G',
    finger: '4',
    alt: {'string': 'D', 'finger': '0'},
  );

  test('G4 prefers fingered (G4 = G-string finger 4)', () {
    final r = resolveFingeringEntry(g4Entry, 'fingered');
    expect(r.string, 'G');
    expect(r.finger, '4');
  });

  test('G4 prefers open (D-string open)', () {
    final r = resolveFingeringEntry(g4Entry, 'open');
    expect(r.string, 'D');
    expect(r.finger, '0');
  });

  // D4 = MIDI 62 on D string is open: primary open, alt fingered
  // G-string open (MIDI 55)
  final g3Open = (
    string: 'G',
    finger: '0',
    alt: null,
  );

  test('G3 (open G) has no alt — always open regardless of preference', () {
    final rFingered = resolveFingeringEntry(g3Open, 'fingered');
    expect(rFingered.string, 'G');
    expect(rFingered.finger, '0');
    final rOpen = resolveFingeringEntry(g3Open, 'open');
    expect(rOpen.string, 'G');
    expect(rOpen.finger, '0');
  });

  // A4 = MIDI 69: D-string finger 4, alt A-string open
  final a4Entry = (
    string: 'D',
    finger: '4',
    alt: {'string': 'A', 'finger': '0'},
  );

  test('A4 fingered stays on D string finger 4', () {
    final r = resolveFingeringEntry(a4Entry, 'fingered');
    expect(r.string, 'D');
    expect(r.finger, '4');
  });

  test('A4 open goes to A-string open', () {
    final r = resolveFingeringEntry(a4Entry, 'open');
    expect(r.string, 'A');
    expect(r.finger, '0');
  });

  // E4 = MIDI 64: D-string finger 1
  final e4Entry = (
    string: 'D',
    finger: '1',
    alt: null,
  );

  test('E4 D-string finger 1 regardless of preference', () {
    final r = resolveFingeringEntry(e4Entry, 'open');
    expect(r.string, 'D');
    expect(r.finger, '1');
    final r2 = resolveFingeringEntry(e4Entry, 'fingered');
    expect(r2.string, 'D');
    expect(r2.finger, '1');
  });
}
