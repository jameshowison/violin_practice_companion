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

  test('highlightDownbeatOnly defaults to off', () {
    expect(service.highlightDownbeatOnly, isFalse);
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
}
