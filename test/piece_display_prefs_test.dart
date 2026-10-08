import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/note_number_mode.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/models/violin_string_palette.dart';
import 'package:violin_practice_companion/services/piece_display_prefs.dart';
import 'package:violin_practice_companion/services/providers.dart';

Piece _piece(String id) =>
    Piece(id: id, title: id, musicXmlFilePath: '/x/$id.musicxml', sections: const []);

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

  test('defaults: fret numbers and underlined strings', () async {
    final c = await containerWith({});
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    expect(c.read(noteNumberModeProvider), NoteNumberMode.mandolinFret);
    expect(c.read(stringColourStyleProvider), StringColourStyle.underline);
  });

  test('a change is saved for that piece and restored for it alone', () async {
    final c = await containerWith({});
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    c.read(displayModeProvider.notifier).state = DisplayMode.staffFingering;
    c.read(showChordsProvider.notifier).state = false;
    c.read(staffSpacingProvider.notifier).state = 0.1;
    c.read(lyricVerseProvider.notifier).state = null;

    c.read(selectedPieceProvider.notifier).state = _piece('b');
    expect(c.read(displayModeProvider), DisplayMode.staff);
    expect(c.read(showChordsProvider), isTrue);
    expect(c.read(staffSpacingProvider), staffSpacingDefault);
    expect(c.read(lyricVerseProvider), 1);

    // A fresh container over the same prefs is a relaunch.
    final relaunch = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(relaunch.dispose);
    relaunch.read(selectedPieceProvider.notifier).state = _piece('a');
    expect(relaunch.read(displayModeProvider), DisplayMode.staffFingering);
    expect(relaunch.read(showChordsProvider), isFalse);
    expect(relaunch.read(staffSpacingProvider), 0.1);
    expect(relaunch.read(lyricVerseProvider), isNull);
  });

  test('opening a piece writes nothing', () async {
    final c = await containerWith({});
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    c.read(displayModeProvider);
    c.read(stringColourStyleProvider);
    expect(prefs.getKeys().where((k) => k.startsWith('display.')), isEmpty);
  });

  test('changing back to the default overwrites the saved value', () async {
    final c = await containerWith({'display.view.a': 'tab'});
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    expect(c.read(displayModeProvider), DisplayMode.tab);
    c.read(displayModeProvider.notifier).state = DisplayMode.staff;
    expect(prefs.getString('display.view.a'), 'staff');
  });

  test('an unreadable saved value falls back to the default', () async {
    final c = await containerWith({'display.view.a': 'noSuchView'});
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    expect(c.read(displayModeProvider), DisplayMode.staff);
  });

  test('without preferences the settings still work for the session', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    c.read(showChordsProvider.notifier).state = false;
    expect(c.read(showChordsProvider), isFalse);
  });
}
