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

  final muteChanges = <bool>[];

  @override
  void onMuteChanged(bool muted) => muteChanges.add(muted);
}

/// A recording-like player whose playback begins before the count — an intro.
class _IntroPlaybackService extends _FakeClockPlaybackService {
  _IntroPlaybackService(super.generator);

  double? introStart;

  @override
  double? get introStartSeconds => introStart;
}

class _NoCountPlaybackService extends _FakeClockPlaybackService {
  _NoCountPlaybackService(super.generator);

  @override
  bool get supportsCountIn => false;
}

/// A player that schedules ahead on its own clock, as the web one does: only
/// [clockNow] and [startLookaheadSeconds] are faked, so [currentPlaybackSeconds]
/// and the schedule both come from the base.
class _OwnClockPlaybackService extends PlaybackServiceBase {
  _OwnClockPlaybackService(super.generator);

  double clock = 100.0;

  @override
  double clockNow() => clock;

  @override
  double get startLookaheadSeconds => 0.25;

  @override
  void onPlayStarted(MidiData data, double startOffsetSeconds) {}

  @override
  void onStopped() {}

  @override
  void onTick(double playbackTime, MidiData data) {}
}

/// A player that strikes notes from [onTick] but is heard [latency] later —
/// the iOS soundfont player on a Bluetooth or AirPlay output.
class _StrikeAheadPlaybackService extends PlaybackServiceBase {
  _StrikeAheadPlaybackService(super.generator);

  static const latency = 0.5;
  double clock = 100.0;
  final ticks = <double>[];

  @override
  double clockNow() => clock;

  @override
  double get startLookaheadSeconds => latency;

  @override
  double get strikeAheadSeconds => latency;

  @override
  void onPlayStarted(MidiData data, double startOffsetSeconds) {}

  @override
  void onStopped() {}

  @override
  void onTick(double playbackTime, MidiData data) => ticks.add(playbackTime);
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

  group('muted', () {
    test('tells the player once per real change', () {
      expect(service.muted, isFalse);
      service.muted = true;
      service.muted = true;
      service.muted = false;
      expect(service.muteChanges, [true, false]);
    });

    test('silences the sound without stopping playback', () {
      service.play(fromMeasure: 1);
      service.muted = true;
      expect(service.playbackState, PlaybackState.playing);
      service.stop();
      expect(service.muted, isTrue, reason: 'mute outlives a stop, like loop');
    });
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

  group('scheduleFrom', () {
    // A 1s note, a 2s note tied over the barline at 2s, then a 1s note.
    const d = MidiData(
      notes: [
        ScheduledNote(0, 1, 60),
        ScheduledNote(1, 3, 62),
        ScheduledNote(3, 4, 64),
      ],
      measureOnsetSeconds: [0, 2],
      measureNumbers: [1, 2],
      totalDurationSeconds: 4,
      measureNoteTimings: [],
      highlightEvents: [],
    );
    List<(double, double, int)> sched(double start, double end) => [
          for (final n in PlaybackServiceBase.scheduleFrom(d, start, end))
            (n.onsetSeconds, n.offsetSeconds, n.midiNote),
        ];

    test('strikes a note held over the start at the start', () {
      expect(sched(2, 4), [(2.0, 3.0, 62), (3.0, 4.0, 64)]);
    });

    test('drops a note that ends on the start and cuts one at the end', () {
      expect(sched(1, 3.5), [(1.0, 3.0, 62), (3.0, 3.5, 64)]);
    });

    test('an empty range schedules nothing', () {
      expect(sched(2, 2), isEmpty);
    });
  });

  group('count-in ticks', () {
    late _IntroPlaybackService svc;
    const plan = (labels: [1, 2, 3], totalUnits: 24, unit: 8); // 3 beats

    setUp(() async {
      svc = _IntroPlaybackService(MidiGenerator.forTest());
      await svc.loadPieceAtBpm(piece, 60); // a beat is 1s
    });

    tearDown(() => svc.dispose());

    test('counts beats and reports fractional beat position', () {
      svc.play(fromMeasure: 2, countIn: plan);
      final start = svc.startOffsetSeconds;
      expect(svc.countInNotifier.value!.totalBeats, 3);
      svc.fakeSeconds = start - 1.5;
      svc.debugTick();
      expect(svc.countInNotifier.value!.index, 1);
      expect(svc.countInNotifier.value!.introProgress, isNull);
      expect(svc.countInBeatPosition(),
          closeTo(1.5 + (svc.highlightLeadSeconds + PlaybackServiceBase.countInDotExtraLeadSeconds), 1e-9),
          reason: 'the dot leads by the highlight lead, as the notes do');
      svc.fakeSeconds = start;
      expect(svc.countInBeatPosition(), isNull);
      svc.debugTick();
      expect(svc.countInNotifier.value, isNull);
    });

    test('a sub-beat pickup leaves a fractional total', () {
      svc.play(
          fromMeasure: 2, countIn: (labels: [1, 2, 3], totalUnits: 20, unit: 8));
      expect(svc.countInNotifier.value!.totalBeats, 2.5);
    });

    test('an intro before the count reports progress, then the count', () {
      svc.fakeSeconds = 0;
      svc.play(fromMeasure: 2, countIn: plan);
      final start = svc.startOffsetSeconds; // 3s
      // Intro from 4s before the count starts.
      svc.introStart = start - 3 - 4;
      svc.play(fromMeasure: 2, countIn: plan);
      expect(svc.countInNotifier.value!.introProgress, 0.0);
      svc.fakeSeconds = start - 3 - 2; // halfway through the intro
      svc.debugTick();
      expect(svc.countInNotifier.value!.introProgress, closeTo(0.5, 0.01));
      expect(svc.countInBeatPosition(),
          closeTo(-2 + (svc.highlightLeadSeconds + PlaybackServiceBase.countInDotExtraLeadSeconds), 1e-9));
      svc.fakeSeconds = start - 2.5; // half a beat into the count
      svc.debugTick();
      expect(svc.countInNotifier.value!.introProgress, isNull);
      expect(svc.countInNotifier.value!.index, 0);
    });

    test('a bar opening on a rest lands the count on its first note', () async {
      // Like Happy Farmer's pickup: the bar starts with a rest, so the count's
      // numbers end on the barline but the first note is heard a beat later.
      final rest = NoteEvent(
          pitch: 'R',
          midiNumber: 0,
          octave: 4,
          noteValue: NoteValue.quarter,
          dotted: false,
          isRest: true);
      final rested = _IntroPlaybackService(MidiGenerator.forTest());
      await rested.loadPieceAtBpm(
          ParsedPiece(
            keySignature: 'C',
            keyFifths: 0,
            keyMode: KeyMode.major,
            measures: [
              Measure(number: 1, notes: [rest, _quarter(62), _quarter(64)]),
            ],
          ),
          60);
      rested.play(fromMeasure: 1, countIn: plan);
      expect(rested.countInLandingSeconds, closeTo(1, 1e-9));
      expect(rested.countInNotifier.value!.totalBeats, closeTo(4, 1e-9));
      rested.fakeSeconds = 0.5; // past the barline, during the rest
      rested.debugTick();
      expect(rested.countInNotifier.value, isNotNull,
          reason: 'still counting into the first heard note');
      expect(rested.countInBeatPosition(),
          closeTo(3.5 + (rested.highlightLeadSeconds + PlaybackServiceBase.countInDotExtraLeadSeconds), 1e-9));
      rested.fakeSeconds = 1.0;
      rested.debugTick();
      expect(rested.countInNotifier.value, isNull);
      rested.dispose();
    });

    test('a player that cannot count in starts without one', () async {
      final unaligned = _NoCountPlaybackService(MidiGenerator.forTest());
      await unaligned.loadPieceAtBpm(piece, 60);
      unaligned.play(fromMeasure: 2, countIn: plan);
      expect(unaligned.countInNotifier.value, isNull);
      expect(unaligned.activeCountIn, isNull);
      unaligned.dispose();
    });
  });

  group('one clock for the sound and the highlight', () {
    late _OwnClockPlaybackService own;

    setUp(() async {
      own = _OwnClockPlaybackService(MidiGenerator.forTest());
      await own.loadPieceAtBpm(piece, 60);
    });

    tearDown(() => own.dispose());

    test('the start sounds after the lookahead and the count-in', () {
      // 3s of count at 60 BPM: 24 units of 1/8 beat.
      own.play(fromMeasure: 2, countIn: (labels: [1, 2, 3], totalUnits: 24, unit: 8));
      expect(own.playStartClock, closeTo(100.0 + 0.25 + 3.0, 1e-9));
      expect(own.scheduledNotes.first.onsetSeconds, own.startOffsetSeconds);
    });

    test('playback time reaches the start exactly when the first note sounds',
        () {
      own.play(fromMeasure: 2, countIn: (labels: [1, 2, 3], totalUnits: 24, unit: 8));
      own.clock = own.playStartClock! - 0.5;
      expect(own.currentPlaybackSeconds(), closeTo(own.startOffsetSeconds - 0.5, 1e-9));
      own.clock = own.playStartClock!;
      expect(own.currentPlaybackSeconds(), closeTo(own.startOffsetSeconds, 1e-9));
    });

    test('a selection is scheduled only up to its end', () {
      own.play(fromMeasure: 1, toMeasure: 2);
      expect(own.scheduledNotes.length, 6);
      expect(own.scheduledNotes.last.offsetSeconds, lessThanOrEqualTo(6.0));
    });
  });

  group('striking ahead of the output latency', () {
    late _StrikeAheadPlaybackService ahead;
    const l = _StrikeAheadPlaybackService.latency;

    setUp(() async {
      ahead = _StrikeAheadPlaybackService(MidiGenerator.forTest());
      await ahead.loadPieceAtBpm(piece, 60);
    });

    tearDown(() => ahead.dispose());

    test('the first notes are struck during the count, a latency early', () {
      ahead.play(fromMeasure: 2, countIn: (labels: [1, 2, 3], totalUnits: 24, unit: 8));
      final start = ahead.playStartClock!;
      ahead.clock = start - l - 0.1;
      ahead.debugTick();
      expect(ahead.ticks, isEmpty, reason: 'too early to strike anything');
      ahead.clock = start - l;
      ahead.debugTick();
      expect(ahead.ticks.single,
          closeTo(ahead.startOffsetSeconds - l, 1e-9));
    });

    test('a loop re-enters a latency early, so the seam has no gap', () {
      ahead.loopEnabled = true;
      ahead.play(fromMeasure: 1, toMeasure: 1); // one 3s bar
      final firstPass = ahead.playStartClock!;
      ahead.clock = firstPass + 3.0 - l; // heard: 0.5s before the bar ends
      ahead.debugTick();
      expect(ahead.playbackState, PlaybackState.playing);
      expect(ahead.playStartClock, closeTo(firstPass + 3.0, 1e-9),
          reason: 'next pass heard exactly as this one ends');
    });

    test('without looping, it stops when the end is heard, not struck', () {
      ahead.play(fromMeasure: 1, toMeasure: 1);
      final t0 = ahead.playStartClock!;
      ahead.clock = t0 + 3.0 - l;
      ahead.debugTick();
      expect(ahead.playbackState, PlaybackState.playing);
      ahead.clock = t0 + 3.0;
      ahead.debugTick();
      expect(ahead.playbackState, PlaybackState.stopped);
    });
  });
}
