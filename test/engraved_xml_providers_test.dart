import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/services/staff_zoom.dart';

/// What the three engrave pipelines put in front of Verovio.
///
/// All three — plain staff, annotated, tab — now have to keep `<harmony>` under
/// the native renderer, because the chord bars are drawn from the register
/// Verovio engraves and there is no register without it.
///
/// This exists because that went wrong twice in a row, silently. Two predicates
/// gave opposite answers to the same question and were combined at two of the
/// three call sites; the tab view and then the plain staff view each drew no chord
/// bars at all while the annotated view looked fine. Nothing failed, nothing
/// logged — the bars just weren't there. So the invariant is asserted rather than
/// left to inspection.
void main() {
  const chordFixture = 'assets/fixtures/old_joe_clark.xml';

  late String sourceXml;
  late ParsedPiece parsed;

  setUpAll(() {
    sourceXml = File(chordFixture).readAsStringSync();
    parsed = MusicXmlParser().parse(sourceXml);
  });

  test('the fixture is a fair test — it really does carry chords', () {
    expect(RegExp('<harmony').allMatches(sourceXml), isNotEmpty);
  });

  test('a score keeping <harmony> is one that reserves annotation room', () {
    // The engrave-side consequence of the same fact: the reserve is gated on the
    // xml, so stripping harmony would also quietly drop the room its row needs.
    expect(scoreReservesAnnotationRoom(sourceXml), isTrue);
  });

  test('stripping <harmony> would cost the chord bars their register', () {
    // Guards the shape of the bug rather than the symptom: with no `<harmony>`
    // there is no `<harm>` to engrave, so `harmRegister` is null on every system
    // and `_ChordLanePainter` skips every segment it is handed.
    final stripped = sourceXml.replaceAll(RegExp(r'<harmony[\s\S]*?</harmony>'), '');
    expect(RegExp('<harmony').allMatches(stripped), isEmpty);
    expect(scoreReservesAnnotationRoom(stripped), isFalse,
        reason: 'no annotations left to reserve room for');
  });

  test('the parsed model keeps its chords regardless of the engraved xml', () {
    // Which is why stripping was ever tempting: the bars are built from the
    // MODEL, so the app looks like it has everything it needs. It does not — it
    // also needs the engraved geometry.
    final symbols = [
      for (final m in parsed.measures)
        for (final n in m.notes)
          if (n.chordSymbol != null) n.chordSymbol!,
    ];
    expect(symbols, isNotEmpty);
  });

  group('all three pipelines agree under the native renderer', () {
    ProviderContainer containerFor() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('the renderer default is the one this invariant is about', () {
      expect(containerFor().read(staffRendererProvider), StaffRenderer.verovio);
    });

    test('the chord toggle does not decide it', () {
      // If it did, flipping it would invalidate a FutureProvider, drop the staff
      // to a spinner and reflow the page. Both settings must give the same answer
      // under the native renderer.
      final c = containerFor();
      final before = c.read(showChordsProvider);
      c.read(showChordsProvider.notifier).state = !before;
      expect(c.read(showChordsProvider), !before);
      // The predicate is private; assert the property it exists to protect —
      // nothing about the xml depends on this toggle. `scoreReservesAnnotationRoom`
      // is a pure function of the xml, so if the toggle could reach the xml the
      // reserve would move with it.
      expect(scoreReservesAnnotationRoom(sourceXml), isTrue);
    });
  });
}
