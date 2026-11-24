import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:pitch_tuner/pitch_tuner.dart' show Transposition;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/app_edition.dart';
import 'package:violin_practice_companion/models/fingering_group_palette.dart';
import 'package:violin_practice_companion/models/instrument_profile.dart';
import 'package:violin_practice_companion/models/recorder_fingering.dart';
import 'package:violin_practice_companion/services/instrument_setting.dart';
import 'package:violin_practice_companion/services/instrument_view.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/piece_display_prefs.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/widgets/hole_diagram.dart';
import 'package:violin_practice_companion/widgets/recorder_fingering_panel.dart';

import 'support/bundled_scores.dart';

/// The keyless Irish flute in D (docs/plan.md §7.5): the recorder's wind
/// path with a six-hole chart, at sounding pitch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const flute = InstrumentProfile.irishFlute;
  final chart = HoleFingeringChart.irishFluteKeyless;
  HoleFingering f(String p) => HoleFingering.parse(p);

  group('the profile', () {
    test('treble, D4 to D6, at sounding pitch, no strings', () {
      expect(flute.clef, trebleClef);
      expect((flute.lowestMidi, flute.highestMidi), (62, 86));
      expect(flute.transposition, Transposition.concert);
      expect(flute.hasStrings, isFalse);
      expect(flute.fingeringChart, same(chart));
    });

    test('a wind alignment over its fundamentals', () {
      final a = flute.alignment;
      expect(a.ringSeconds, lessThan(0.3));
      expect(a.minFrequencyHz, lessThan(293)); // D4
      expect(a.maxFrequencyHz, greaterThan(1175)); // D6
    });

    test('Stringlings offers it, with the wind features', () async {
      expect(instrumentsOffered(AppEdition.stringlings),
          contains(InstrumentSet.irishFlute));
      SharedPreferences.setMockInitialValues(
          {instrumentSetKey: InstrumentSet.irishFlute.name});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appEditionProvider.overrideWithValue(AppEdition.stringlings),
      ]);
      addTearDown(c.dispose);
      expect(c.read(instrumentProfileProvider).id, 'irishFlute');
      final fe = c.read(instrumentFeaturesProvider);
      expect((fe.tabView, fe.chords, fe.stringFingering, fe.stringTuner),
          (false, false, false, false));
    });

    test('every bundled tune mostly lands in D4..D6', () {
      for (final file in bundledScoreFiles()) {
        final xml = file.readAsStringSync();
        final view = InstrumentView.of(flute, xml);
        expect(view.keepsPitchClasses, isTrue);
        final notes = MusicXmlParser()
            .parse(view.apply(xml))
            .measures
            .expand((m) => m.notes)
            .where((n) => !n.isRest)
            .toList();
        final inRange =
            notes.where((n) => n.midiNumber >= 62 && n.midiNumber <= 86).length;
        expect(inRange / notes.length, greaterThan(0.95), reason: file.path);
      }
    });
  });

  group('the keyless chart', () {
    test('every chromatic note from D4 to D6, six holes, no thumb', () {
      for (var m = 62; m <= 86; m++) {
        final e = chart[m];
        expect(e, isNotNull, reason: 'MIDI $m');
        for (final fg in [e!.fingering, ...e.alternates]) {
          expect(fg.hasThumb, isFalse);
          expect(fg.holes.length, 6);
        }
      }
      expect(chart[61], isNull);
      expect(chart[87], isNull);
    });

    test('the D scale and C natural, both octaves', () {
      const scale = {
        62: 'xxx xxx', // D
        64: 'xxx xxo', // E
        66: 'xxx xoo', // F♯
        67: 'xxx ooo', // G
        69: 'xxo ooo', // A
        71: 'xoo ooo', // B
        72: 'oxx ooo', // C natural, cross-fingered
        73: 'ooo ooo', // C♯
      };
      for (final e in scale.entries) {
        expect(chart[e.key]!.fingering.pattern, e.value, reason: '${e.key}');
        expect(chart[e.key + 12]!.fingering.pattern, e.value,
            reason: '${e.key + 12}: the same fingers, overblown');
        expect(chart[e.key]!.overblown, isFalse);
        expect(chart[e.key + 12]!.overblown, isTrue);
      }
      expect(chart[86]!.fingering.pattern, 'oxx ooo'); // D6
    });

    test('the notes the charts differ on are marked', () {
      expect([
        for (final e in chart.entries.entries)
          if (!e.value.verified) e.key
      ], [68, 70, 72, 80, 82, 84]);
    });

    test('groups: left hand, both hands, and the high octave', () {
      expect(chart[67]!.group, FingeringGroup.leftHand); // G4
      expect(chart[73]!.group, FingeringGroup.leftHand); // C♯5
      expect(chart[62]!.group, FingeringGroup.bothHands); // D4
      expect(chart[74]!.group, FingeringGroup.overblown); // D5
      expect(chart[86]!.group, FingeringGroup.overblown); // D6
      expect(fingeringGroupLabel(FingeringGroup.overblown), 'High octave');
    });

    test('register words: high from D5', () {
      expect(registerWord(73, highFrom: chart.highFrom), 'low');
      expect(registerWord(74, highFrom: chart.highFrom), 'high');
    });
  });

  group('change instructions', () {
    test('six holes, counted per hand, no thumb', () {
      expect(fingeringChangeLines(null, f('xxx ooo')),
          ['Start with left 1, left 2, left 3']);
      expect(fingeringChangeLines(f('xxx ooo'), f('xxx xxx')),
          ['Put down right 1, right 2, right 3']);
      expect(fingeringChangeLines(f('xoo ooo'), f('oxx ooo')),
          ['Put down left 2, left 3', 'Lift left 1']);
      expect(fingeringChangeLines(f('xxx xoo'), f('xxx xho')),
          ['Half-cover right 2']);
      expect(changedHoles(f('xxo ooo'), f('xoo ooo')), {2});
    });

    test('an octave leap: the same fingers, and the breath says so', () {
      expect(fingeringChangeLines(chart.fingeringFor(62), chart.fingeringFor(74)!),
          isEmpty);
      expect(breathChangeLine(chart[62], chart[74]!), 'Blow harder');
      expect(breathChangeLine(chart[74], chart[62]!), 'Blow softer');
      expect(breathChangeLine(chart[62], chart[64]!), isNull);
      expect(breathChangeLine(null, chart[74]!), isNull);
    });
  });

  testWidgets('the landscape panel draws six holes and says "Blow harder"',
      (tester) async {
    // D4 then D5: an octave leap on the same fingers.
    final parsed = MusicXmlParser().parse('''<?xml version="1.0"?>
<score-partwise version="3.1"><part-list><score-part id="P1"><part-name>F</part-name></score-part></part-list>
<part id="P1"><measure number="1"><attributes><divisions>1</divisions><time><beats>2</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>
<note><pitch><step>D</step><octave>4</octave></pitch><duration>1</duration><type>quarter</type></note>
<note><pitch><step>D</step><octave>5</octave></pitch><duration>1</duration><type>quarter</type></note>
</measure></part></score-partwise>''');
    SharedPreferences.setMockInitialValues(
        {instrumentSetKey: InstrumentSet.irishFlute.name});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(874, 402);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appEditionProvider.overrideWithValue(AppEdition.stringlings),
        parsedPieceProvider.overrideWith((ref) async => parsed),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: FingeringPanelSlot(
            highlight: ValueNotifier<HighlightEvent?>(null),
            events: () => const [],
            child: const Placeholder(key: ValueKey('score')),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.byKey(const ValueKey('recorder_fingering_panel')), findsOneWidget);
    expect(find.text('Start with left 1, left 2, left 3, right 1, right 2, right 3'),
        findsOneWidget);
    expect(find.byType(HoleDiagram), findsNWidgets(2));

    final c = ProviderScope.containerOf(
        tester.element(find.byKey(const ValueKey('score'))));
    c.read(fingeringFocusProvider.notifier).state = (measure: 1, note: 1);
    await tester.pump();
    expect(find.text('Blow harder'), findsOneWidget);
    expect(find.text('Same fingers'), findsNothing);
    expect(find.text('high'), findsOneWidget);
  });
}
