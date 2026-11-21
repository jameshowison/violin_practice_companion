import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/services/measure_edit_session.dart';
import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:violin_practice_companion/services/providers.dart';

// Two bars in D major: the editor opens bar 2 while bar 1 stays as written,
// which is what "in context" depends on — a draft may only touch its own bar.
const _xml = '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="3.1">
  <part-list><score-part id="P1"><part-name>Violin</part-name></score-part></part-list>
  <part id="P1">
    <measure number="1">
      <attributes>
        <divisions>4</divisions>
        <key><fifths>2</fifths><mode>major</mode></key>
        <time><beats>4</beats><beat-type>4</beat-type></time>
      </attributes>
      <note><pitch><step>D</step><octave>4</octave></pitch><duration>16</duration><type>whole</type></note>
    </measure>
    <measure number="2">
      <note><pitch><step>E</step><octave>4</octave></pitch><duration>8</duration><type>half</type></note>
      <note><pitch><step>G</step><octave>4</octave></pitch><duration>8</duration><type>half</type></note>
    </measure>
  </part>
</score-partwise>''';

void main() {
  final parsed = MusicXmlParser().parse(_xml);
  const piece = Piece(
      id: 'p1', title: 'Test', musicXmlFilePath: '/nowhere.xml', sections: []);

  Future<ProviderContainer> container() async {
    final c = ProviderContainer(overrides: [
      parsedPieceProvider.overrideWith((ref) async => parsed),
    ]);
    addTearDown(c.dispose);
    c.read(selectedPieceProvider.notifier).state = piece;
    await c.read(parsedPieceProvider.future);
    return c;
  }

  Future<void> afterDraftDelay() => Future<void>.delayed(
      MeasureEditController.draftDelay + const Duration(milliseconds: 50));

  test('opening a bar seeds it clean, with no draft', () async {
    final c = await container();
    expect(c.read(measureEditProvider.notifier).start(2), isTrue);
    final s = c.read(measureEditProvider)!;
    expect(s.measureNumber, 2);
    expect(s.notes.map((n) => n.pitch), ['E4', 'G4']);
    expect(s.selectedIndex, 0);
    expect(s.isDirty, isFalse);
    await afterDraftDelay();
    expect(c.read(measureDraftProvider), isNull);
  });

  test('an edit shows on the cards at once and drafts after the delay',
      () async {
    final c = await container();
    final ctl = c.read(measureEditProvider.notifier)..start(2);
    ctl.stepPitch(1); // E4 → F#4 (D major)
    expect(c.read(measureEditProvider)!.notes.first.pitch, 'F#4');
    expect(c.read(measureEditProvider)!.isDirty, isTrue);
    expect(c.read(measureDraftProvider), isNull, reason: 'debounced');

    await afterDraftDelay();
    final draft = c.read(measureDraftProvider)!;
    expect(draft.pieceId, 'p1');
    expect(draft.measureNumber, 2);

    // The draft, applied, changes its bar and only its bar.
    final applied = MusicXmlParser().parse(draft.applyTo(_xml));
    expect(applied.measures[0].notes.map((n) => n.pitch), ['D4']);
    expect(applied.measures[1].notes.map((n) => n.pitch), ['F#4', 'G4']);
  });

  test('the draft follows the latest edit, not the first', () async {
    final c = await container();
    final ctl = c.read(measureEditProvider.notifier)..start(2);
    ctl.stepPitch(1);
    await afterDraftDelay();
    ctl.stepPitch(1); // F#4 → G4
    await afterDraftDelay();
    final applied =
        MusicXmlParser().parse(c.read(measureDraftProvider)!.applyTo(_xml));
    expect(applied.measures[1].notes.first.pitch, 'G4');
  });

  test('a repeat toggle is drafted, so the score shows the barline', () async {
    final c = await container();
    final ctl = c.read(measureEditProvider.notifier)..start(2);
    ctl.toggleRepeatEnd();
    await afterDraftDelay();
    final draft = c.read(measureDraftProvider)!;
    expect(draft.repeatEnd, isTrue);
    expect(MusicXmlParser().parse(draft.applyTo(_xml)).measures[1].repeatEnd,
        isTrue);
  });

  test('a section marker makes the bar dirty but is not drafted', () async {
    final c = await container();
    final ctl = c.read(measureEditProvider.notifier)..start(2);
    ctl.setSectionMarker('B');
    await afterDraftDelay();
    final s = c.read(measureEditProvider)!;
    expect(s.isDirty, isTrue);
    expect(s.markerAtSelection?.label, 'B');
    expect(c.read(measureDraftProvider), isNull);
  });

  test('cancel drops the session and its draft', () async {
    final c = await container();
    final ctl = c.read(measureEditProvider.notifier)..start(2);
    ctl.delete();
    await afterDraftDelay();
    expect(c.read(measureDraftProvider), isNotNull);
    ctl.cancel();
    expect(c.read(measureEditProvider), isNull);
    expect(c.read(measureDraftProvider), isNull);
  });

  test('with no piece selected there is no xml, draft or not', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // No selected piece → nothing to serve, draft or not.
    c.read(measureDraftProvider.notifier).state = MeasureDraft(
        pieceId: 'other',
        measureNumber: 2,
        notes: const [],
        divisions: 4,
        repeatStart: false,
        repeatEnd: false);
    expect(await c.read(pieceMusicXmlProvider.future), isNull);
  });
}
