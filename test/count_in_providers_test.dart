import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/providers.dart';

/// Where Play starts, and what it counts, for the two ways a pickup gets
/// numbered in the wild.
///
/// Both bugs this pins were reported from the device: playback beginning on the
/// first FULL bar instead of the anacrusis (a pickup numbered 0 is skipped by a
/// literal `fromMeasure: 1`), and the count still running to four over a tune
/// whose pickup is beat four.
void main() {
  NoteEvent note(NoteValue value, {bool rest = false}) => NoteEvent(
        pitch: rest ? 'R' : 'A',
        midiNumber: rest ? 0 : 69,
        octave: 4,
        noteValue: value,
        dotted: false,
        isRest: rest,
        scoreFinger: null,
      );

  Measure full(int number) =>
      Measure(number: number, notes: List.filled(4, note(NoteValue.quarter)));

  /// 4/4 with a one-quarter anacrusis, numbered [pickupNumber].
  ParsedPiece withPickup(int pickupNumber,
          {List<NoteEvent> hidden = const []}) =>
      ParsedPiece(
        keySignature: 'A',
        keyFifths: 3,
        keyMode: KeyMode.major,
        beatsPerMeasure: 4,
        beatType: 4,
        measures: [
          Measure(
              number: pickupNumber,
              notes: [note(NoteValue.quarter)],
              hiddenLeadNotes: hidden),
          full(pickupNumber + 1),
          full(pickupNumber + 2),
        ],
      );

  ParsedPiece noPickup() => ParsedPiece(
        keySignature: 'C',
        keyFifths: 0,
        keyMode: KeyMode.major,
        beatsPerMeasure: 4,
        beatType: 4,
        measures: [full(1), full(2)],
      );

  Future<ProviderContainer> containerFor(ParsedPiece piece) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(overrides: [
      parsedPieceProvider.overrideWith((ref) async => piece),
    ]);
    addTearDown(container.dispose);
    await container.read(parsedPieceProvider.future);
    return container;
  }

  group('playbackStartMeasureProvider', () {
    test("starts on a pickup numbered 1 (Devil's Dream)", () async {
      final c = await containerFor(withPickup(1));
      expect(c.read(playbackStartMeasureProvider), 1);
    });

    test('starts on a pickup numbered 0 (The Happy Farmer)', () async {
      // The reported bug: a literal `fromMeasure: 1` resolves to the first FULL
      // bar here, dropping the anacrusis.
      final c = await containerFor(withPickup(0));
      expect(c.read(playbackStartMeasureProvider), 0);
    });

    test('a practice selection wins', () async {
      final c = await containerFor(withPickup(0));
      c.read(measureSelectionProvider.notifier).state =
          const MeasureSelection(2, 3);
      expect(c.read(playbackStartMeasureProvider), 2);
    });
  });

  group('resolvedCountInProvider', () {
    List<int> labels(ProviderContainer c) =>
        c.read(resolvedCountInProvider)?.labels ?? const [];

    test('counts 1 2 3 into a one-beat pickup, whichever way it is numbered',
        () async {
      expect(labels(await containerFor(withPickup(1))), [1, 2, 3]);
      expect(labels(await containerFor(withPickup(0))), [1, 2, 3]);
    });

    test('counts the whole bar when there is no pickup', () async {
      expect(labels(await containerFor(noPickup())), [1, 2, 3, 4]);
    });

    test('a hidden lead rest is part of the pickup', () async {
      // Happy Farmer's shape: the anacrusis owns a whole beat, half of it a
      // hidden rest, so the count still yields exactly one beat.
      final piece = ParsedPiece(
        keySignature: 'G',
        keyFifths: 1,
        keyMode: KeyMode.major,
        beatsPerMeasure: 4,
        beatType: 4,
        measures: [
          Measure(
              number: 0,
              notes: [note(NoteValue.eighth)],
              hiddenLeadNotes: [note(NoteValue.eighth, rest: true)]),
          full(1),
        ],
      );
      expect(labels(await containerFor(piece)), [1, 2, 3]);
    });

    test('a selection starting on a full bar gets the full count', () async {
      final c = await containerFor(withPickup(1));
      c.read(measureSelectionProvider.notifier).state =
          const MeasureSelection(2, 3);
      expect(labels(c), [1, 2, 3, 4]);
    });

    test('Off means no count at all', () async {
      final c = await containerFor(withPickup(1));
      c.read(countInProvider.notifier).preview(0);
      expect(c.read(resolvedCountInProvider), isNull);
    });
  });
}
