import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/key_signature.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/services/measure_edit_session.dart';
import 'package:violin_practice_companion/services/measure_xml_editor.dart';
import 'package:violin_practice_companion/services/musicxml_parser.dart';
import 'package:violin_practice_companion/services/providers.dart';

// A tune in G (one sharp), as a scan that misread D major would write it:
// every C is C♮ because the recogniser thought the key had no C♯.
//   bar 1: C5, F♯5 (from the key), C4 with a written ♮, C4 (carries the ♮)
//   bar 2: C5 under a slur, C5 tied into…
//   bar 3: C5
const _xml = '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name>Violin</part-name></score-part></part-list>
  <part id="P1">
    <measure number="1">
      <attributes>
        <divisions>1</divisions>
        <key><fifths>1</fifths></key>
        <time><beats>4</beats><beat-type>4</beat-type></time>
      </attributes>
      <note><pitch><step>C</step><octave>5</octave></pitch><duration>1</duration><type>quarter</type></note>
      <note><pitch><step>F</step><alter>1</alter><octave>5</octave></pitch><duration>1</duration><type>quarter</type></note>
      <note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><type>quarter</type><accidental>natural</accidental></note>
      <note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><type>quarter</type></note>
    </measure>
    <measure number="2">
      <note><pitch><step>C</step><octave>5</octave></pitch><duration>2</duration><type>half</type><notations><slur type="start" number="1"/></notations></note>
      <note><pitch><step>C</step><octave>5</octave></pitch><duration>2</duration><tie type="start"/><type>half</type><notations><tied type="start"/></notations></note>
    </measure>
    <measure number="3">
      <note><pitch><step>C</step><octave>5</octave></pitch><duration>4</duration><tie type="stop"/><type>whole</type><notations><tied type="stop"/></notations></note>
    </measure>
  </part>
</score-partwise>''';

List<List<String>> _pitches(String xml) => [
      for (final m in MusicXmlParser().parse(xml).measures)
        [for (final n in m.notes) n.pitch],
    ];

void main() {
  group('KeySignature.rekeyBar', () {
    KeyedNote n(String step, int alter,
            {int octave = 4, bool written = false, bool tieStop = false}) =>
        (
          step: step,
          octave: octave,
          alter: alter,
          written: written,
          tieStop: tieStop,
        );

    test('moves the notes that follow the key, and only those', () {
      final (alters, _) = KeySignature.rekeyBar([
        n('C', 0), // follows G → C♯ in D
        n('F', 1), // follows G, and D agrees
        n('G', 1, written: true), // its own ♯ stays
        null, // a rest
        n('B', -1), // B♭ in G was never the key's: leave it
      ], 1, 2);
      expect(alters, [1, 1, 1, null, -1]);
    });

    test('a written accidental holds to the barline on its own line only',
        () {
      final (alters, _) = KeySignature.rekeyBar([
        n('C', 0, written: true),
        n('C', 0), // carries the ♮
        n('C', 0, octave: 5), // another line: follows the key
      ], 1, 2);
      expect(alters, [0, 0, 1]);
    });

    test('a tie keeps the pitch it continues, across the barline', () {
      // Tied in from a bar the change doesn't touch: stays C♮.
      final (kept, _) = KeySignature.rekeyBar(
          [n('C', 0, tieStop: true), n('C', 0)], 1, 2,
          carryIn: KeySignature.unchangedCarry(n('C', 0)));
      expect(kept, [0, 1]);
      // Tied in from a bar that moved: moves with it.
      final (moved, _) = KeySignature.rekeyBar(
          [n('C', 0, tieStop: true)], 1, 2,
          carryIn: (step: 'C', octave: 4, oldAlter: 0, newAlter: 1));
      expect(moved, [1]);
    });

    test('labels', () {
      expect(KeySignature.label(0), '0');
      expect(KeySignature.label(2), '2♯');
      expect(KeySignature.label(-3), '3♭');
      expect(KeySignature.signs(2), 'F♯ C♯');
      expect(KeySignature.signs(-2), 'B♭ E♭');
    });
  });

  group('MeasureXmlEditor key changes', () {
    test('fixing the opening key re-spells the whole piece', () {
      final out = MeasureXmlEditor.setKeyChange(_xml, 1, 2);
      final parsed = MusicXmlParser().parse(out);
      expect(parsed.keyFifths, 2);
      expect(_pitches(out), [
        ['C#5', 'F#5', 'C4', 'C4'],
        ['C#5', 'C#5'],
        ['C#5'],
      ]);
      // Re-spelt in place, not rebuilt: the slur and the tie survive.
      expect(out, contains('<slur type="start" number="1"/>'));
      expect(out, contains('<tie type="stop"/>'));
      expect('<key>'.allMatches(out).length, 1);
    });

    test('a change mid-piece leaves the bars before it alone', () {
      final out = MeasureXmlEditor.setKeyChange(_xml, 2, 2);
      final parsed = MusicXmlParser().parse(out);
      expect(parsed.keyFifths, 1);
      expect(parsed.measures[1].keyChange, 2);
      expect(parsed.keyAt(2), 2);
      expect(_pitches(out), [
        ['C5', 'F#5', 'C4', 'C4'],
        ['C#5', 'C#5'],
        ['C#5'],
      ]);
    });

    test('a change stops at the next key', () {
      final withChange = MeasureXmlEditor.setKeyChange(_xml, 2, 2);
      // G → F at bar 1: its F♯ (from the key) becomes F; bars 2–3 keep D.
      final out = MeasureXmlEditor.setKeyChange(withChange, 1, -1);
      expect(_pitches(out), [
        ['C5', 'F5', 'C4', 'C4'],
        ['C#5', 'C#5'],
        ['C#5'],
      ]);
    });

    test('the key goes before the time in its attributes', () {
      final out = MeasureXmlEditor.setKeyChange(
          _xml.replaceFirst('<key><fifths>1</fifths></key>', ''), 1, 2);
      expect(out.indexOf('<key>'), lessThan(out.indexOf('<time>')));
      expect(out.indexOf('<divisions>'), lessThan(out.indexOf('<key>')));
    });

    test('removing a change re-spells back into the key before it', () {
      final withChange = MeasureXmlEditor.setKeyChange(_xml, 2, 2);
      final out = MeasureXmlEditor.removeKeyChange(withChange, 2);
      expect(_pitches(out), _pitches(_xml));
      expect(MusicXmlParser().parse(out).measures[1].keyChange, isNull);
      expect(MeasureXmlEditor.removeKeyChange(_xml, 1), _xml,
          reason: 'the opening key is changed, never removed');
    });

    test('rejects a key that is not one', () {
      expect(() => MeasureXmlEditor.setKeyChange(_xml, 1, 8),
          throwsArgumentError);
      expect(() => MeasureXmlEditor.setKeyChange(_xml, 9, 2),
          throwsArgumentError);
    });
  });

  group('the measure editor', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final parsed = MusicXmlParser().parse(_xml);
    const piece = Piece(
        id: 'p1', title: 'Test', musicXmlFilePath: '/nowhere.xml', sections: []);

    Future<ProviderContainer> container() async {
      final c = ProviderContainer(overrides: [
        parsedPieceProvider.overrideWith((ref) async => parsed),
      ]);
      addTearDown(c.dispose);
      await c.read(fingeringMapperProvider).init();
      c.read(selectedPieceProvider.notifier).state = piece;
      await c.read(parsedPieceProvider.future);
      return c;
    }

    Future<void> afterDraftDelay() => Future<void>.delayed(
        MeasureEditController.draftDelay + const Duration(milliseconds: 50));

    test('opens with the key in force', () async {
      final c = await container();
      c.read(measureEditProvider.notifier).start(1);
      var s = c.read(measureEditProvider)!;
      expect(s.keyChange, 1);
      expect(s.key, 1);
      c.read(measureEditProvider.notifier).start(2);
      s = c.read(measureEditProvider)!;
      expect(s.keyChange, isNull, reason: 'bar 2 carries on in G');
      expect(s.keyBefore, 1);
    });

    test('a key fix re-spells the bar at once and drafts the rest', () async {
      final c = await container();
      final ctl = c.read(measureEditProvider.notifier)..start(1);
      ctl.setKeyChange(2);
      final s = c.read(measureEditProvider)!;
      expect(s.notes.map((n) => n.pitch), ['C#5', 'F#5', 'C4', 'C4']);
      expect(s.isDirty, isTrue);
      expect(s.keyChanged, isTrue);
      expect(s.notesChanged, isFalse,
          reason: 'a key-only fix re-spells the file in place on Save');

      await afterDraftDelay();
      final draft = c.read(measureDraftProvider)!;
      expect(draft.notes, isNull);
      expect(draft.key, (fifths: 2));
      expect(_pitches(draft.applyTo(_xml)), [
        ['C#5', 'F#5', 'C4', 'C4'],
        ['C#5', 'C#5'],
        ['C#5'],
      ]);
    });

    test('pitch steps follow the bar\'s new key', () async {
      final c = await container();
      final ctl = c.read(measureEditProvider.notifier)..start(1);
      ctl.setKeyChange(2);
      ctl.select(1); // F♯5
      ctl.stepPitch(-1); // → E5
      ctl.stepPitch(-1); // → D5
      ctl.stepPitch(-1); // → C♯5 in D, not C5
      expect(c.read(measureEditProvider)!.notes[1].pitch, 'C#5');
    });

    test('a key fix on top of note edits keeps both', () async {
      final c = await container();
      final ctl = c.read(measureEditProvider.notifier)..start(1);
      ctl.select(3);
      ctl.stepPitch(1); // C4 (carried ♮) → D4
      ctl.setKeyChange(2);
      final s = c.read(measureEditProvider)!;
      expect(s.notes.map((n) => n.pitch), ['C#5', 'F#5', 'C4', 'D4']);
      await afterDraftDelay();
      final draft = c.read(measureDraftProvider)!;
      expect(draft.notes, isNotNull);
      expect(_pitches(draft.applyTo(_xml))[0], ['C#5', 'F#5', 'C4', 'D4']);
    });

    test('changing back leaves nothing to save', () async {
      final c = await container();
      final ctl = c.read(measureEditProvider.notifier)..start(1);
      ctl.setKeyChange(2);
      ctl.setKeyChange(1);
      final s = c.read(measureEditProvider)!;
      expect(s.isDirty, isFalse);
      expect(s.notes.map((n) => n.pitch), ['C5', 'F#5', 'C4', 'C4']);
      await afterDraftDelay();
      expect(c.read(measureDraftProvider), isNull);
    });

    test('the first bar\'s key cannot be removed', () async {
      final c = await container();
      final ctl = c.read(measureEditProvider.notifier)..start(1);
      ctl.setKeyChange(null);
      expect(c.read(measureEditProvider)!.keyChange, 1);
    });
  });
}
