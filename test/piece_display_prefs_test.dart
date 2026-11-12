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

  test('defaults: violin fingering and underlined strings', () async {
    final c = await containerWith({});
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    expect(c.read(noteNumberModeProvider), NoteNumberMode.violinFingering);
    expect(c.read(stringColourStyleProvider), StringColourStyle.underline);
  });

  test('note names and notehead colours are off until asked for', () async {
    final c = await containerWith({});
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    expect(c.read(showNoteNamesProvider), isFalse);
    expect(c.read(colourNoteheadsByStringProvider), isFalse);
    c.read(showNoteNamesProvider.notifier).state = true;
    c.read(colourNoteheadsByStringProvider.notifier).state = true;
    c.read(selectedPieceProvider.notifier).state = _piece('b');
    expect(c.read(showNoteNamesProvider), isFalse);
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    expect(c.read(showNoteNamesProvider), isTrue);
    expect(c.read(colourNoteheadsByStringProvider), isTrue);
  });

  test('a change is saved for that piece and restored for it alone', () async {
    final c = await containerWith({});
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    c.read(displayModePrefProvider.notifier).state = DisplayMode.tab;
    c.read(showChordsPrefProvider.notifier).state = false;
    c.read(staffSpacingProvider.notifier).state = 0.1;
    c.read(lyricVerseProvider.notifier).state = null;

    c.read(selectedPieceProvider.notifier).state = _piece('b');
    expect(c.read(displayModePrefProvider), DisplayMode.staffFingering);
    expect(c.read(showChordsPrefProvider), isTrue);
    expect(c.read(staffSpacingProvider), staffSpacingDefault);
    expect(c.read(lyricVerseProvider), 1);

    // A fresh container over the same prefs is a relaunch.
    final relaunch = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(relaunch.dispose);
    relaunch.read(selectedPieceProvider.notifier).state = _piece('a');
    expect(relaunch.read(displayModePrefProvider), DisplayMode.tab);
    expect(relaunch.read(showChordsPrefProvider), isFalse);
    expect(relaunch.read(staffSpacingProvider), 0.1);
    expect(relaunch.read(lyricVerseProvider), isNull);
  });

  test('opening a piece writes nothing', () async {
    final c = await containerWith({});
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    c.read(displayModePrefProvider);
    c.read(stringColourStyleProvider);
    expect(prefs.getKeys().where((k) => k.startsWith('display.')), isEmpty);
  });

  test('changing back to the default overwrites the saved value', () async {
    final c = await containerWith({'display.view.a': 'tab'});
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    expect(c.read(displayModePrefProvider), DisplayMode.tab);
    c.read(displayModePrefProvider.notifier).state = DisplayMode.staffFingering;
    expect(prefs.getString('display.view.a'), 'staffFingering');
  });

  test('an unreadable saved value falls back to the default', () async {
    final c = await containerWith({'display.view.a': 'noSuchView'});
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    expect(c.read(displayModePrefProvider), DisplayMode.staffFingering);
  });

  test('without preferences the settings still work for the session', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(selectedPieceProvider.notifier).state = _piece('a');
    c.read(showChordsPrefProvider.notifier).state = false;
    expect(c.read(showChordsPrefProvider), isFalse);
  });
}
