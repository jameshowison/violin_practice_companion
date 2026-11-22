import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/app_edition.dart';
import 'package:violin_practice_companion/models/instrument_profile.dart';
import 'package:violin_practice_companion/models/recorder_fingering.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/piece_display_prefs.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/services/wind_fingering.dart';
import 'package:violin_practice_companion/widgets/hole_diagram.dart';
import 'package:violin_practice_companion/widgets/recorder_fingering_panel.dart';

/// The recorder's fingering chart, the change instructions, and the side
/// panel (docs/family/windlings-app.md, step W2).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final chart = HoleFingeringChart.sopranoBaroque;
  HoleFingering f(String p) => HoleFingering.parse(p);

  group('the soprano baroque chart', () {
    test('has every chromatic note from written C4 to D6', () {
      for (var m = 60; m <= 86; m++) {
        expect(chart[m], isNotNull, reason: 'MIDI $m');
      }
      expect(chart[59], isNull);
      expect(chart[87], isNull);
      expect(InstrumentProfile.recorder.fingeringChart, same(chart));
      expect(InstrumentProfile.violin.fingeringChart, isNull);
    });

    test('the low octave, C4 to D5, exactly', () {
      const low = {
        60: 'x xxx xxxx', // C4
        61: 'x xxx xxxh', // C♯4
        62: 'x xxx xxxo', // D4
        63: 'x xxx xxho', // D♯4
        64: 'x xxx xxoo', // E4
        65: 'x xxx xoxx', // F4
        66: 'x xxx oxxo', // F♯4
        67: 'x xxx oooo', // G4
        68: 'x xxo xxho', // G♯4
        69: 'x xxo oooo', // A4
        70: 'x xox xooo', // B♭4
        71: 'x xoo oooo', // B4
        72: 'x oxo oooo', // C5
        73: 'o xxo oooo', // C♯5
        74: 'o oxo oooo', // D5
      };
      for (final e in low.entries) {
        expect(chart[e.key]!.fingering.pattern, e.value, reason: 'MIDI ${e.key}');
        expect(chart[e.key]!.verified, isTrue);
      }
    });

    test('only the thumb is half-holed, and only 6 and 7 are half-covered',
        () {
      for (final e in chart.entries.values) {
        for (final fg in [e.fingering, ...e.alternates]) {
          for (var i = 1; i <= 5; i++) {
            expect(fg.hole(i), isNot(HoleState.half), reason: '$fg');
          }
        }
      }
    });

    test('groups: left hand, both hands, thumb off', () {
      expect(chart[67]!.group, FingeringGroup.leftHand); // G4
      expect(chart[71]!.group, FingeringGroup.leftHand); // B4
      expect(chart[72]!.group, FingeringGroup.leftHand); // C5
      expect(chart[62]!.group, FingeringGroup.bothHands); // D4
      expect(chart[70]!.group, FingeringGroup.bothHands); // B♭4
      expect(chart[74]!.group, FingeringGroup.thumbOff); // D5
      expect(chart[76]!.group, FingeringGroup.thumbOff); // E5, half-holed
    });

    test('the entries the charts disagree on are marked', () {
      final unverified = [
        for (final e in chart.entries.entries)
          if (!e.value.verified) e.key
      ];
      expect(unverified, [82, 85, 86]);
    });
  });

  group('change instructions', () {
    test('B to high D: put down left 2, lift thumb and left 1', () {
      expect(fingeringChangeLines(chart.fingeringFor(71), chart.fingeringFor(74)!),
          ['Put down left 2', 'Lift thumb, left 1']);
    });

    test('right-hand holes are counted on the right hand', () {
      expect(fingeringChangeLines(chart.fingeringFor(67), chart.fingeringFor(64)!),
          ['Put down right 1, right 2']);
      expect(fingeringChangeLines(chart.fingeringFor(64), chart.fingeringFor(65)!),
          ['Put down right 3, right 4', 'Lift right 2']);
    });

    test('the thumb half-holed, and a double hole half-covered', () {
      expect(fingeringChangeLines(chart.fingeringFor(74), chart.fingeringFor(76)!),
          ['Put down left 1, left 3, right 1, right 2', 'Half-hole thumb']);
      expect(fingeringChangeLines(f('x xxx xxxx'), f('x xxx xxxh')),
          ['Half-cover right 4']);
      expect(fingeringChangeLines(f('h xxx oooo'), f('x xxx oooo')),
          ['Put down thumb']);
    });

    test('the same fingering says nothing; the first note says where to start',
        () {
      expect(fingeringChangeLines(f('x xxo oooo'), f('x xxo oooo')), isEmpty);
      expect(fingeringChangeLines(null, f('x xxo oooo')),
          ['Start with thumb, left 1, left 2']);
      expect(changedHoles(f('x xoo oooo'), f('o oxo oooo')), {0, 1, 2});
      expect(changedHoles(null, f('o oxo oooo')), isEmpty);
    });

    test('register words', () {
      expect(registerWord(71), 'low');
      expect(registerWord(72), 'high');
      expect(registerWord(86), 'high');
    });
  });

  group('the current note', () {
    // Two bars: B A G (rest) | B D(tied) D.
    const xml = '''<?xml version="1.0"?>
<score-partwise version="3.1"><part-list><score-part id="P1"><part-name>R</part-name></score-part></part-list>
<part id="P1">
<measure number="1"><attributes><divisions>1</divisions><key><fifths>1</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>
<note><pitch><step>B</step><octave>4</octave></pitch><duration>1</duration><type>quarter</type></note>
<note><pitch><step>A</step><octave>4</octave></pitch><duration>1</duration><type>quarter</type></note>
<note><pitch><step>G</step><octave>4</octave></pitch><duration>1</duration><type>quarter</type></note>
<note><rest/><duration>1</duration><type>quarter</type></note>
</measure>
<measure number="2">
<note><pitch><step>B</step><octave>4</octave></pitch><duration>1</duration><type>quarter</type></note>
<note><pitch><step>D</step><octave>5</octave></pitch><duration>1</duration><type>quarter</type><tie type="start"/><notations><tied type="start"/></notations></note>
<note><pitch><step>D</step><octave>5</octave></pitch><duration>1</duration><type>quarter</type><tie type="stop"/><notations><tied type="stop"/></notations></note>
<note><pitch><step>D</step><octave>5</octave></pitch><duration>1</duration><type>quarter</type></note>
</measure>
</part></score-partwise>''';
    final parsed = MusicXmlParser().parse(xml);

    test('document order leaves out rests and tie continuations', () {
      final order = playingOrder(parsed, const []);
      expect([for (final n in order) n.midi], [71, 69, 67, 71, 74, 74]);
      expect([for (final n in order) (n.measureNumber, n.noteIndex)],
          [(1, 0), (1, 1), (1, 2), (2, 0), (2, 1), (2, 3)]);
    });

    HighlightEvent ev(int m, int n, {int perf = 0, bool tie = false}) =>
        HighlightEvent(
            measureNumber: m,
            noteIndex: n,
            isLong: false,
            onsetSeconds: 0,
            offsetSeconds: 0,
            beatPosition: 0,
            performanceIndex: perf,
            isTieContinuation: tie);

    test('playing: the played note; over a rest the next; over a tie the held',
        () {
      final events = [
        for (var n = 0; n < 4; n++) ev(1, n, perf: 0),
        for (var n = 0; n < 4; n++) ev(2, n, perf: 1, tie: n == 2),
      ];
      final order = playingOrder(parsed, events);
      expect(order.length, 6);
      expect(focusIndex(order, playing: ev(1, 1, perf: 0)), 1);
      expect(focusIndex(order, playing: ev(1, 3, perf: 0)), 3,
          reason: 'the rest shows the B to come');
      expect(focusIndex(order, playing: ev(2, 2, perf: 1, tie: true)), 4,
          reason: 'the tie shows the D still held');
    });

    test('stopped: the tapped note, else the selection, else the first', () {
      final order = playingOrder(parsed, const []);
      expect(focusIndex(order), 0);
      expect(focusIndex(order, tapped: (measure: 2, note: 1)), 4);
      expect(focusIndex(order, tapped: (measure: 1, note: 3)), 0,
          reason: 'a tapped rest falls back to its bar');
      final sel = (startMeasure: 2, startNote: 0, endMeasure: 2, startPerf: -1);
      expect(focusIndex(order, selection: sel), 3);
      expect(focusIndex(order, tapped: (measure: 1, note: 2), selection: sel), 3,
          reason: 'a tap outside the selection gives way to it');
    });
  });

  group('the side panel', () {
    final parsed = MusicXmlParser().parse('''<?xml version="1.0"?>
<score-partwise version="3.1"><part-list><score-part id="P1"><part-name>R</part-name></score-part></part-list>
<part id="P1"><measure number="1"><attributes><divisions>1</divisions><time><beats>2</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>
<note><pitch><step>B</step><octave>4</octave></pitch><duration>1</duration><type>quarter</type></note>
<note><pitch><step>D</step><octave>5</octave></pitch><duration>1</duration><type>quarter</type></note>
</measure></part></score-partwise>''');

    Future<void> pumpScreen(WidgetTester tester, AppEdition edition,
        {required Size size}) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final highlight = ValueNotifier<HighlightEvent?>(null);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          appEditionProvider.overrideWithValue(edition),
          parsedPieceProvider.overrideWith((ref) async => parsed),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: FingeringPanelSlot(
              highlight: highlight,
              events: () => const [],
              child: const Placeholder(key: ValueKey('score')),
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('landscape recorder: the panel, on the right of the score',
        (tester) async {
      await pumpScreen(tester, AppEdition.windlings, size: const Size(874, 402));
      final panel = find.byKey(const ValueKey('recorder_fingering_panel'));
      expect(panel, findsOneWidget);
      expect(tester.getTopLeft(panel).dx,
          greaterThan(tester.getTopRight(find.byKey(const ValueKey('score'))).dx - 1));
      expect(tester.widget<Text>(find.byKey(const ValueKey('fingering_panel_note'))).data, 'B');
      expect(tester.widget<Text>(find.byKey(const ValueKey('fingering_panel_next'))).data, 'D');
      expect(find.byType(HoleDiagram), findsNWidgets(2));
      expect(find.text('Start with thumb, left 1'), findsOneWidget);
    });

    testWidgets('a tap on the second note moves the panel to it',
        (tester) async {
      await pumpScreen(tester, AppEdition.windlings, size: const Size(874, 402));
      final c = ProviderScope.containerOf(
          tester.element(find.byKey(const ValueKey('score'))));
      c.read(fingeringFocusProvider.notifier).state = (measure: 1, note: 1);
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const ValueKey('fingering_panel_note'))).data, 'D');
      expect(find.text('Put down left 2'), findsOneWidget);
      expect(find.text('Lift thumb, left 1'), findsOneWidget);
      expect(find.text('Last note'), findsOneWidget);
    });

    testWidgets('portrait recorder: no panel', (tester) async {
      await pumpScreen(tester, AppEdition.windlings, size: const Size(402, 874));
      expect(find.byKey(const ValueKey('recorder_fingering_panel')), findsNothing);
    });

    testWidgets('landscape violin: no panel, the score as it was',
        (tester) async {
      await pumpScreen(tester, AppEdition.stringlings, size: const Size(874, 402));
      expect(find.byKey(const ValueKey('recorder_fingering_panel')), findsNothing);
    });
  });
}
