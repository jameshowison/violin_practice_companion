import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/providers.dart';

/// What the "New chords" block will draw, decided before it is built.
///
/// This is load-bearing beyond the block itself: the phone's bottom tray now
/// holds nothing but those diagrams, so an empty answer here is what tells it
/// to leave off the drag handle rather than offer a drawer onto an empty panel.
void main() {
  NoteEvent note({String? chord}) => NoteEvent(
        pitch: 'A',
        midiNumber: 69,
        octave: 4,
        noteValue: NoteValue.quarter,
        dotted: false,
        isRest: false,
        chordSymbol: chord,
      );

  /// One measure per entry; each entry is that bar's chord symbols, with null
  /// meaning "a note carrying no chord change".
  ParsedPiece pieceWith(List<List<String?>> bars) => ParsedPiece(
        keySignature: 'G',
        keyFifths: 1,
        keyMode: KeyMode.major,
        measures: [
          for (final (i, bar) in bars.indexed)
            Measure(
                number: i + 1, notes: [for (final c in bar) note(chord: c)]),
        ],
      );

  Future<List<String>> shapesFor(ParsedPiece? piece) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(overrides: [
      parsedPieceProvider.overrideWith((ref) async => piece),
    ]);
    addTearDown(container.dispose);
    await container.read(parsedPieceProvider.future);
    return [for (final s in container.read(pieceChordShapesProvider)) s.name];
  }

  test('distinct chords, in order of first appearance', () async {
    // G repeats and must not earn a second diagram; C appears after D and must
    // stay in that order, since the block reads as "here is what this tune
    // introduces, as you meet it".
    expect(
      await shapesFor(pieceWith([
        ['G', null, 'D'],
        ['G', 'C'],
        ['D'],
      ])),
      ['G', 'D', 'C'],
    );
  });

  test('a chord with no shape in the library is dropped, not faked', () async {
    // The library is ten triads and no sevenths. D7 has no entry, so it is
    // silently omitted rather than degraded to a D.
    expect(await shapesFor(pieceWith([
      ['G', 'D7', 'C'],
    ])), ['G', 'C']);
  });

  test('a tune of nothing but sevenths yields nothing at all', () async {
    // The case that makes the tray hide its handle — and the case that looks
    // identical to the feature being broken, which is why it is pinned here.
    expect(await shapesFor(pieceWith([
      ['A7', 'D7', 'E7'],
    ])), isEmpty);
  });

  test('no chord symbols anywhere yields nothing', () async {
    expect(await shapesFor(pieceWith([
      [null, null],
    ])), isEmpty);
  });

  test('no piece loaded yields nothing rather than throwing', () async {
    expect(await shapesFor(null), isEmpty);
  });
}
