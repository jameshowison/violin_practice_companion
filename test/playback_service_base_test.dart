import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/models/note_event.dart';
import 'package:violin_practice_companion/models/parsed_piece.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:violin_practice_companion/services/playback_service_base.dart';

/// Minimal concrete subclass for testing the shared highlight-tracking logic
/// in isolation, with no real audio output and a caller-controlled clock (so
/// [PlaybackServiceBase.highlightDownbeatOnly]'s resync can be exercised at an
/// exact mid-measure instant without waiting on real timers).
class _FakeClockPlaybackService extends PlaybackServiceBase {
  _FakeClockPlaybackService(super.generator);

  double? fakeSeconds;

  /// Simulates AudioSyncPlaybackService's real "nothing to highlight yet"
  /// case (a recording's unmatched intro still playing) — see
  /// PlaybackServiceBase.initialHighlightSeconds.
  bool noInitialHighlight = false;

  @override
  double? currentPlaybackSeconds() => fakeSeconds;

  @override
  double? initialHighlightSeconds() =>
      noInitialHighlight ? null : super.initialHighlightSeconds();

  @override
  void onPlayStarted(MidiData data, double startOffsetSeconds) {}

  @override
  void onStopped() {}

  @override
  void onTick(double playbackTime, MidiData data) {}
}

NoteEvent _quarter(int midi) => NoteEvent(
      pitch: 'X',
      midiNumber: midi,
      octave: 4,
      noteValue: NoteValue.quarter,
      dotted: false,
      isRest: false,
    );

void main() {
  // Three measures of three quarter notes each, at 60 BPM (1s/quarter): each
  // measure is exactly 3 seconds, with notes 0/1/2 onsetting at +0s/+1s/+2s
  // from the measure's own onset. Measure onsets land at 0s, 3s, 6s.
  final piece = ParsedPiece(
    keySignature: 'C',
    keyFifths: 0,
    keyMode: KeyMode.major,
    measures: [
      Measure(number: 1, notes: [_quarter(60), _quarter(62), _quarter(64)]),
      Measure(number: 2, notes: [_quarter(65), _quarter(67), _quarter(69)]),
      Measure(number: 3, notes: [_quarter(71), _quarter(72), _quarter(74)]),
    ],
  );

  late _FakeClockPlaybackService service;

  setUp(() async {
    service = _FakeClockPlaybackService(MidiGenerator.forTest());
    await service.loadPieceAtBpm(piece, 60);
  });

  tearDown(() => service.dispose());

  // The base class deliberately defaults this ON, and says why at
  // playback_service_base.dart:22-30 — intra-measure note timing is
  // interpolated rather than aligned, so the downbeat is the only highlight
  // granularity that has actually been verified against the audio. This
  // assertion was written against the earlier default and never updated when
  // the default was flipped, so it has been the repo's one failing test ever
  // since. It is the only thing asserting the default either way, which is why
  // it is corrected rather than deleted.
  test('highlightDownbeatOnly defaults to on', () {
    expect(service.highlightDownbeatOnly, isTrue);
  });

  test('toggling highlightDownbeatOnly resyncs the highlight to the current '
      'measure\'s first note, and restores full detail when turned back off',
      () {
    service.play(fromMeasure: 2);
    // 1s into measure 2 (onset 3.0) lands exactly on that measure's second
    // note (index 1, onset 4.0) in full-detail mode.
    service.fakeSeconds = 4.0;

    service.highlightDownbeatOnly = true;

    expect(service.currentMeasureNotifier.value, 2);
    expect(service.notifierForMeasure(2).value, 0);
    expect(service.currentHighlightNotifier.value?.noteIndex, 0);
    expect(service.currentHighlightNotifier.value?.measureNumber, 2);

    service.highlightDownbeatOnly = false;

    expect(service.notifierForMeasure(2).value, 1);
    expect(service.currentHighlightNotifier.value?.noteIndex, 1);
  });

  test('setting highlightDownbeatOnly to its current value is a no-op', () {
    service.play(fromMeasure: 2);
    service.fakeSeconds = 4.0;
    // Force one resync to establish the full-detail pointer at note index 1.
    service.highlightDownbeatOnly = true;
    service.highlightDownbeatOnly = false;
    expect(service.notifierForMeasure(2).value, 1);

    // Re-assigning the same (false) value must not force another resync —
    // otherwise this would also pick up fakeSeconds=5.0 and move to note
    // index 2.
    service.fakeSeconds = 5.0;
    service.highlightDownbeatOnly = false;

    expect(service.notifierForMeasure(2).value, 1,
        reason: 'no-op set must not re-resync against the new clock value');
  });

  test(
      'a service with nothing to highlight at play() time shows no '
      'highlight until playback reaches the first note', () {
    service.noInitialHighlight = true;
    service.play(fromMeasure: 1);

    expect(service.currentMeasureNotifier.value, isNull);
    expect(service.currentHighlightNotifier.value, isNull);
    expect(service.notifierForMeasure(1).value, isNull);

    // Still before the first note (e.g. mid-recording-intro): forcing a
    // resync — what _tick does every 40ms — must not conjure a highlight
    // out of nothing.
    service.fakeSeconds = -2.0;
    service.highlightLeadSeconds = 0.05; // any distinct value forces a resync
    expect(service.currentHighlightNotifier.value, isNull);

    // Now at the first note's onset: highlighting picks up normally.
    service.fakeSeconds = 0.0;
    service.highlightLeadSeconds = 0.06;
    expect(service.currentMeasureNotifier.value, 1);
    expect(service.currentHighlightNotifier.value?.noteIndex, 0);
  });

  test('downbeat-only holds the same note index across an entire measure',
      () {
    service.play(fromMeasure: 1);
    service.highlightDownbeatOnly = true;

    for (final t in [0.0, 1.0, 2.9]) {
      service.fakeSeconds = t;
      service.highlightDownbeatOnly = false; // force a resync at this t...
      service.highlightDownbeatOnly = true; //  ...then back to downbeat-only
      expect(service.notifierForMeasure(1).value, 0,
          reason: 'at t=$t within measure 1');
    }
  });

  group('a section that starts or ends mid-bar', () {
    test('play starts on fromNote, not the barline', () {
      service.play(fromMeasure: 2, fromNote: 1);
      expect(service.startOffsetSeconds, 4.0);
    });

    testWidgets('play stops before toNote of toMeasure', (tester) async {
      service.play(fromMeasure: 1, toMeasure: 2, toNote: 1);
      service.fakeSeconds = 3.9;
      await tester.pump(const Duration(milliseconds: 50));
      expect(service.playbackState, PlaybackState.playing);
      service.fakeSeconds = 4.0; // measure 2, note 1
      await tester.pump(const Duration(milliseconds: 50));
      expect(service.playbackState, PlaybackState.stopped);
    });

    testWidgets('a loop goes back to fromNote', (tester) async {
      service.loopEnabled = true;
      service.play(fromMeasure: 1, fromNote: 2, toMeasure: 2, toNote: 1);
      service.fakeSeconds = 4.0;
      await tester.pump(const Duration(milliseconds: 50));
      expect(service.playbackState, PlaybackState.playing);
      expect(service.startOffsetSeconds, 2.0);
      service.stop();
    });
  });

  group('a section pinned to one pass of a repeat', () {
    // Played 1, 2, 1, 2, 3: measure onsets at 0s, 3s, 6s, 9s, 12s.
    final repeated = ParsedPiece(
      keySignature: 'C',
      keyFifths: 0,
      keyMode: KeyMode.major,
      measures: [
        Measure(number: 1, notes: [_quarter(60), _quarter(62), _quarter(64)]),
        Measure(
            number: 2,
            notes: [_quarter(65), _quarter(67), _quarter(69)],
            repeatEnd: true),
        Measure(number: 3, notes: [_quarter(71), _quarter(72), _quarter(74)]),
      ],
    );

    setUp(() async => service.loadPieceAtBpm(repeated, 60));

    test('starts on the pass it names, not the first', () {
      service.play(fromMeasure: 2, fromNote: 2, fromIndex: 3);
      expect(service.startOffsetSeconds, 11.0);
    });

    testWidgets('a run from a bar\'s tail to the same note a pass later',
        (tester) async {
      // Devil's Dream's A²: from the `e2` before `:|` round to it again.
      service.play(
          fromMeasure: 2,
          fromNote: 2,
          toMeasure: 2,
          toNote: 2,
          fromIndex: 1,
          toIndex: 3);
      expect(service.startOffsetSeconds, 5.0);
      service.fakeSeconds = 10.9;
      await tester.pump(const Duration(milliseconds: 50));
      expect(service.playbackState, PlaybackState.playing);
      service.fakeSeconds = 11.0;
      await tester.pump(const Duration(milliseconds: 50));
      expect(service.playbackState, PlaybackState.stopped);
    });
  });
}
