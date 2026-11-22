import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:pitch_tuner/pitch_tuner.dart' show Transposition;
import 'package:score_view/score_view.dart' show EngravedMeasureMap;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/app_edition.dart';
import 'package:violin_practice_companion/models/display_mode.dart';
import 'package:violin_practice_companion/models/fingering_density.dart';
import 'package:violin_practice_companion/models/instrument_profile.dart';
import 'package:violin_practice_companion/models/note_annotation.dart';
import 'package:violin_practice_companion/models/string_label_style.dart';
import 'package:violin_practice_companion/screens/settings_screen.dart';
import 'package:violin_practice_companion/services/fingering_annotation_builder.dart';
import 'package:violin_practice_companion/services/fingering_mapper.dart';
import 'package:violin_practice_companion/services/instrument_setting.dart';
import 'package:violin_practice_companion/services/instrument_view.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/piece_display_prefs.dart';
import 'package:violin_practice_companion/services/providers.dart';
import 'package:violin_practice_companion/widgets/notation_switcher.dart';

import 'support/bundled_scores.dart';

/// Windlings (docs/family/windlings-app.md): a third flavor, the soprano
/// recorder alone, with everything string-specific off.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const recorder = InstrumentProfile.recorder;

  late SharedPreferences prefs;
  Future<ProviderContainer> windlings([Map<String, Object> saved = const {}]) async {
    SharedPreferences.setMockInitialValues(saved);
    prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      appEditionProvider.overrideWithValue(AppEdition.windlings),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  List<NoteEvent> notesOf(String xml) =>
      MusicXmlParser().parse(xml).measures.expand((m) => m.notes).toList();

  group('the edition', () {
    test('the flavor names it, and it calls itself Windlings', () {
      expect(AppEdition.fromFlavor('windlings'), AppEdition.windlings);
      expect(AppEdition.windlings.appName, 'Windlings');
      expect(instrumentsOffered(AppEdition.windlings), [InstrumentSet.recorder]);
      expect(instrumentsOffered(AppEdition.stringlings),
          contains(InstrumentSet.recorder));
      expect(instrumentsOffered(AppEdition.mandolin),
          isNot(contains(InstrumentSet.recorder)));
    });

    test('is the recorder, whatever was stored, with the strings off',
        () async {
      final c = await windlings({instrumentSetKey: 'violin'});
      expect(c.read(instrumentSetProvider), InstrumentSet.recorder);
      expect(c.read(instrumentProfileProvider).id, 'recorder');
      final f = c.read(instrumentFeaturesProvider);
      expect((f.tabView, f.chords, f.stringFingering, f.stringTuner),
          (false, false, false, false));
      expect(prefs.getString(instrumentSetKey), 'violin',
          reason: 'the stored value is left alone');
    });

    test('plays at sounding pitch: the schedule is an octave up', () async {
      final c = await windlings();
      expect(c.read(midiGeneratorProvider).soundingSemitones, 12);
    });

    test('a saved Fingering or Combined view opens annotated', () async {
      final c = await windlings();
      for (final saved in [DisplayMode.fingering, DisplayMode.combined]) {
        c.read(displayModePrefProvider.notifier).state = saved;
        expect(c.read(displayModeProvider), DisplayMode.staffFingering);
      }
      c.read(displayModePrefProvider.notifier).state = DisplayMode.jianpu;
      expect(c.read(displayModeProvider), DisplayMode.jianpu);
    });

    testWidgets('the view picker offers no string views', (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: NotationSwitcher(
                  current: DisplayMode.staff,
                  onChanged: (_) {},
                  showTab: false,
                  showStringViews: false))));
      expect(find.text('Staff'), findsOneWidget);
      expect(find.text('Annotated'), findsOneWidget);
      expect(find.text('Fingering'), findsNothing);
      expect(find.text('Combined'), findsNothing);
      expect(find.text('Tab'), findsNothing);
    });

    testWidgets('Settings has no instrument choice, and names the app',
        (tester) async {
      final c = await windlings();
      await tester.pumpWidget(UncontrolledProviderScope(
          container: c, child: const MaterialApp(home: SettingsScreen())));
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('add_player')), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const ValueKey('instrument_setting')), findsNothing);
      expect(find.byType(RadioListTile<InstrumentSet>), findsNothing);
      expect(find.textContaining('Windlings collects no data'), findsOneWidget);
    });
  });

  group('the recorder profile', () {
    test('treble, written C4 to D6, sounding an octave up', () {
      expect(recorder.clef, trebleClef);
      expect((recorder.lowestMidi, recorder.highestMidi), (60, 86));
      expect(recorder.transposition, Transposition.octaveUp);
      expect(recorder.transposition.sounding(60), 72);
      expect(InstrumentProfile.violin.transposition, Transposition.concert);
    });

    test('no strings, so no open-or-4th choice anywhere', () {
      expect(recorder.hasStrings, isFalse);
      expect(recorder.strings, isEmpty);
      for (var m = 48; m <= 96; m++) {
        expect(recorder.hasFourthFingerChoice(m), isFalse, reason: '$m');
      }
      expect(InstrumentProfile.violin.hasFourthFingerChoice(69), isTrue);
    });

    test('a wind alignment: little ring, a band over its fundamentals', () {
      final a = recorder.alignment;
      expect(a.ringSeconds, lessThan(0.3));
      expect(a.minFrequencyHz, lessThan(523)); // C5, the lowest sounding note
      expect(a.maxFrequencyHz, greaterThan(2350)); // D7, the highest
    });

    test('withTranscription keeps the transposition', () {
      expect(recorder.withTranscription(Transcription.none).transposition,
          Transposition.octaveUp);
    });
  });

  group('the written part', () {
    test('every bundled tune lands in the written range', () {
      for (final f in bundledScoreFiles()) {
        final xml = f.readAsStringSync();
        final view = InstrumentView.of(recorder, xml);
        expect(view.keepsPitchClasses, isTrue);
        final notes = notesOf(view.apply(xml)).where((n) => !n.isRest);
        final inRange = notes
            .where((n) => n.midiNumber >= 60 && n.midiNumber <= 86)
            .length;
        expect(inRange / notes.length, greaterThan(0.95), reason: f.path);
      }
    });

    test('a first-position violin tune reads as the violin part does', () {
      final xml = File(scorePath('lightly_row')).readAsStringSync();
      final view = InstrumentView.of(recorder, xml);
      expect(view.interval, (steps: 0, semitones: 0));
      expect(view.isIdentity, isTrue);
      expect(identical(view.apply(xml), xml), isTrue);
    });

    test('a tune below the range is moved up an octave, and edits go back',
        () {
      // Lightly Row an octave down: open-G territory for a violin.
      final down = _transposeXml(
          File(scorePath('lightly_row')).readAsStringSync(), -12);
      final view = InstrumentView.of(recorder, down);
      expect(view.interval, (steps: 7, semitones: 12));
      final shown = notesOf(view.apply(down));
      final source = notesOf(down);
      final back = view.toSource(shown);
      for (var i = 0; i < source.length; i++) {
        if (source[i].isRest) continue;
        expect(shown[i].midiNumber, source[i].midiNumber + 12);
        expect(back[i].midiNumber, source[i].midiNumber);
      }
    });

    test('the schedule sounds the written notes an octave up', () {
      final xml = File(scorePath('lightly_row')).readAsStringSync();
      final piece = MusicXmlParser().parse(xml);
      final concert = MidiGenerator.forTest().generate(piece, 100);
      final sounding =
          MidiGenerator.forTest(soundingSemitones: 12).generate(piece, 100);
      expect(sounding.notes.length, concert.notes.length);
      for (var i = 0; i < concert.notes.length; i++) {
        expect(sounding.notes[i].midiNote, concert.notes[i].midiNote + 12);
        expect(sounding.notes[i].onsetSeconds, concert.notes[i].onsetSeconds);
      }
    });
  });

  group('no string fingering', () {
    test('the mapper leaves every note unfingered, and no label is drawn',
        () async {
      final mapper = FingeringMapper();
      await mapper.init();
      final xml = File(scorePath('lightly_row')).readAsStringSync();
      final piece = MusicXmlParser().parse(xml);
      final violin = mapper.map(piece);
      expect(
          violin.measures
              .expand((m) => m.notes)
              .any((n) => n.fingerNumber != null),
          isTrue,
          reason: 'the violin is fingered');

      final mapped = mapper.map(piece, profile: recorder);
      final notes = mapped.measures.expand((m) => m.notes);
      expect(notes.every((n) => n.fingerString == null && n.fingerNumber == null),
          isTrue);
      final labels = fingeringAnnotations(
        EngravedMeasureMap.identity(mapped.measures.map((m) => m.number)),
        mapped,
        density: FingeringDensity.all,
        policy: FingeringDensityPolicy.values.first,
        colourByString: true,
        stringLabelStyle: StringLabelStyle.always,
      );
      expect(labels, isEmpty);
    });
  });
}

/// [xml] with every pitch moved by [semitones] (whole octaves only).
String _transposeXml(String xml, int semitones) {
  assert(semitones % 12 == 0);
  return xml.replaceAllMapped(RegExp(r'<octave>(\d+)</octave>'),
      (m) => '<octave>${int.parse(m.group(1)!) + semitones ~/ 12}</octave>');
}
