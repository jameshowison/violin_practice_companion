import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/key_signature.dart';

void main() {
  test('C major (0 fifths) has no default accidentals', () {
    for (final step in ['A', 'B', 'C', 'D', 'E', 'F', 'G']) {
      expect(KeySignature.defaultAlter(0, step), 0, reason: step);
    }
  });

  test('D major (2 sharps) defaults F and C sharp only', () {
    expect(KeySignature.defaultAlter(2, 'F'), 1);
    expect(KeySignature.defaultAlter(2, 'C'), 1);
    expect(KeySignature.defaultAlter(2, 'G'), 0);
    expect(KeySignature.defaultAlter(2, 'B'), 0);
  });

  test('F major (1 flat) defaults B flat only', () {
    expect(KeySignature.defaultAlter(-1, 'B'), -1);
    expect(KeySignature.defaultAlter(-1, 'E'), 0);
  });

  test('Bb major (2 flats) defaults B and E flat', () {
    expect(KeySignature.defaultAlter(-2, 'B'), -1);
    expect(KeySignature.defaultAlter(-2, 'E'), -1);
    expect(KeySignature.defaultAlter(-2, 'A'), 0);
  });
}
