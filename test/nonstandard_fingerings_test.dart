import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/nonstandard_fingerings.dart';

NoteEvent _n(String? string, String? finger, {bool rest = false}) => NoteEvent(
      pitch: 'A4',
      midiNumber: 69,
      octave: 4,
      noteValue: NoteValue.quarter,
      dotted: false,
      isRest: rest,
      fingerString: string,
      fingerNumber: finger,
    );

ParsedPiece _piece(List<NoteEvent> notes) => ParsedPiece(
      keySignature: 'G',
      keyFifths: 1,
      keyMode: KeyMode.major,
      measures: [Measure(number: 1, notes: notes)],
    );

void main() {
  test('each L/H label once, by string low to high, verbatim', () {
    final piece = _piece([
      _n('E', '2L'),
      _n('A', '1'),
      _n('A', '2L'),
      _n('G', '3H'),
      _n('E', '2L'),
      _n('D', '3'),
    ]);
    expect(nonStandardFingerings(piece), ['G3H', 'A2L', 'E2L']);
  });

  test('the same finger low and high on one string are both listed', () {
    expect(nonStandardFingerings(_piece([_n('A', '2H'), _n('A', '2L')])),
        ['A2H', 'A2L']);
  });

  test('none when every fingering is standard or missing', () {
    expect(
        nonStandardFingerings(
            _piece([_n('A', '1'), _n(null, null), _n(null, null, rest: true)])),
        isEmpty);
  });
}
