import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/note_number_mode.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/services/instrument_setting.dart';
import 'package:violin_practice_companion/services/piece_display_prefs.dart';
import 'package:violin_practice_companion/services/providers.dart';

Piece _piece(String id) =>
    Piece(id: id, title: id, musicXmlFilePath: '/x/$id.musicxml', sections: const []);

/// The app-wide Instruments setting: violin by default, and in violin mode the
/// mandolin and chord choices a piece has saved are overridden — not erased, so
/// switching back brings them back.
void main() {
  late SharedPreferences prefs;

  Future<ProviderContainer> containerWith(Map<String, Object> saved) async {
    SharedPreferences.setMockInitialValues(saved);
    prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(c.dispose);
    return c;
  }

  // A piece someone set up for the mandolin before the setting existed.
  const mandolinPiece = {
    'display.numbers.a': 'mandolinFret',
    'display.view.a': 'tab',
    'display.chords.a': 'true',
  };

  test('defaults to the violin, with every mandolin feature off', () async {
    final c = await containerWith({});
    expect(c.read(instrumentSetProvider), InstrumentSet.violin);
    final f = c.read(instrumentFeaturesProvider);
    expect([f.fretNumbers, f.tabView, f.chords], [false, false, false]);
  });

  test('violin mode overrides a piece saved for the mandolin', () async {
    final c = await containerWith(mandolinPiece);
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    expect(c.read(noteNumberModeProvider), NoteNumberMode.violinFingering);
    expect(c.read(displayModeProvider), DisplayMode.staffFingering);
    expect(c.read(showChordsProvider), isFalse);
    expect(c.read(pieceChordShapesProvider), isEmpty);
  });

  test('switching to violin and mandolin brings the saved choices back',
      () async {
    final c = await containerWith(mandolinPiece);
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    c.read(noteNumberModeProvider); // read once in violin mode
    c.read(instrumentSetProvider.notifier).state =
        InstrumentSet.violinAndMandolin;
    expect(c.read(noteNumberModeProvider), NoteNumberMode.mandolinFret);
    expect(c.read(displayModeProvider), DisplayMode.tab);
    expect(c.read(showChordsProvider), isTrue);
    // Nothing about the piece was rewritten while it was overridden.
    for (final e in mandolinPiece.entries) {
      expect(prefs.getString(e.key), e.value);
    }
  });

  test('violin mode leaves the views it has alone', () async {
    final c = await containerWith({'display.view.a': 'jianpu'});
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    expect(c.read(displayModeProvider), DisplayMode.jianpu);
  });

  test('the setting is saved and restored', () async {
    final c = await containerWith({});
    c.read(instrumentSetProvider.notifier).state =
        InstrumentSet.violinAndMandolin;
    expect(prefs.getString(instrumentSetKey), 'violinAndMandolin');

    final relaunch = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(relaunch.dispose);
    expect(relaunch.read(instrumentSetProvider),
        InstrumentSet.violinAndMandolin);
  });

  test('opening the app in the default never writes the setting', () async {
    final c = await containerWith({});
    c.read(instrumentSetProvider);
    expect(prefs.getString(instrumentSetKey), isNull);
  });

  test('an unreadable value reads as the violin', () async {
    final c = await containerWith({instrumentSetKey: 'banjo'});
    expect(c.read(instrumentSetProvider), InstrumentSet.violin);
  });
}
