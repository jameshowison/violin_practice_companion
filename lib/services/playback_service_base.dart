import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/count_in.dart';
import '../models/parsed_piece.dart';
import 'midi_generator.dart';

enum PlaybackState { playing, paused, stopped }

/// Shared timing and highlight-tracking logic for both platform implementations.
/// Subclasses handle the actual audio output.
abstract class PlaybackServiceBase {
  final MidiGenerator generator;

  MidiData? _data;
  ParsedPiece? _piece;
  int _bpm = 115;

  bool loopEnabled = false;
  PlaybackState _state = PlaybackState.stopped;
  int _fromMeasure = 1;
  int? _toMeasure;
  DateTime? _t0;
  double _startOffset = 0.0;
  Timer? _timer;

  int _hlPointer = 0;
  int _lastEmittedMeasure = 0;

  // Count-in. Playback time runs from `_startOffset - _countInSeconds` up to
  // `_startOffset`, so the count is simply the stretch where the time cursor sits
  // BEHIND the first note — nothing else in the timing has to know it exists.
  // The plan supplies the numbers and their spacing; this only keeps the clock.
  CountInPlan? _countInPlan;
  double _countInSeconds = 0;
  double _countInBeatSeconds = 0;

  final Map<int, ValueNotifier<int?>> _measureNotifiers = {};
  final ValueNotifier<int?> currentMeasureNotifier = ValueNotifier(null);
  final ValueNotifier<HighlightEvent?> currentHighlightNotifier = ValueNotifier(null);

  /// The count-off in progress, or null when the music is playing (or stopped).
  /// Drives the "1 .. 2 .. 3" display above the time signature.
  final ValueNotifier<CountInTick?> countInNotifier = ValueNotifier(null);

  final _stateCtrl = StreamController<PlaybackState>.broadcast();

  Stream<PlaybackState> get state => _stateCtrl.stream;
  PlaybackState get playbackState => _state;
  int get currentBpm => _bpm;

  PlaybackServiceBase(this.generator);

  ValueNotifier<int?> notifierForMeasure(int n) =>
      _measureNotifiers.putIfAbsent(n, () => ValueNotifier(null));

  Future<void> loadPiece(ParsedPiece piece) async {
    _stopInternal();
    _disposeAndClearNotifiers();
    await generator.init();
    _piece = piece;
    _data = generator.generate(piece, _bpm);
  }

  /// Starts (or resumes) playback of measures [fromMeasure]…[toMeasure].
  ///
  /// [countIn], when given, is counted off before the first note sounds; null
  /// starts immediately. Only the Play/Rewind buttons ask for a count — a loop
  /// repeat and a tempo change both re-enter [play] mid-practice, where counting
  /// in again would be an interruption rather than a service.
  void play({int fromMeasure = 1, int? toMeasure, CountInPlan? countIn}) {
    final d = _data;
    if (d == null) return;
    _stopInternal(silent: true);
    _fromMeasure = fromMeasure;
    _toMeasure = toMeasure;
    // fromMeasure is a Measure.number, not an array index — map it via the
    // document-order measureNumbers list so a pickup (number 0) and any
    // non-1-based numbering resolve correctly. Falls back to the start.
    final fromIdx = d.indexOfMeasure(fromMeasure);
    _startOffset = d.measureOnsetSeconds[fromIdx >= 0 ? fromIdx : 0];
    _countInPlan = countIn;
    final unitSeconds = countInUnitSeconds(_bpm);
    _countInBeatSeconds = countIn == null ? 0 : countIn.unit * unitSeconds;
    _countInSeconds = countIn == null ? 0 : countIn.totalUnits * unitSeconds;
    // t0 goes into the FUTURE by the length of the count. Everything downstream
    // reads `_startOffset + elapsed`, so this makes playback time run *up to*
    // the first note instead of from it — no note sounds and no highlight
    // advances while the cursor is behind the start, so the count-in needs no
    // separate clock, no separate timer and no state machine.
    _t0 = DateTime.now()
        .add(Duration(microseconds: (_countInSeconds * 1e6).round()));
    countInNotifier.value = countIn == null
        ? null
        : (labels: countIn.labels, index: 0, startMeasure: fromMeasure);

    final events = d.highlightEvents;
    if (events.isNotEmpty) {
      _hlPointer = _findPointer(events, _startOffset);
      _lastEmittedMeasure = events[_hlPointer].measureNumber;
      currentMeasureNotifier.value = _lastEmittedMeasure;
      notifierForMeasure(_lastEmittedMeasure).value = events[_hlPointer].noteIndex;
      currentHighlightNotifier.value = events[_hlPointer];
    }

    _emitState(PlaybackState.playing);
    _timer = Timer.periodic(const Duration(milliseconds: 40), _tick);
    onPlayStarted(d, _startOffset);
  }

  void pause() {
    if (_state != PlaybackState.playing) return;
    _timer?.cancel();
    _timer = null;
    countInNotifier.value = null;
    _emitState(PlaybackState.paused);
    onStopped();
  }

  void stop() => _stopInternal();

  void setTempo(int bpm) {
    final wasPlaying = _state == PlaybackState.playing;
    final savedMeasure = _lastEmittedMeasure > 0 ? _lastEmittedMeasure : _fromMeasure;
    final savedTo = _toMeasure;
    _stopInternal(silent: true);
    _bpm = bpm;
    if (_piece != null) _data = generator.generate(_piece!, bpm);
    if (wasPlaying) play(fromMeasure: savedMeasure, toMeasure: savedTo);
  }

  void _stopInternal({bool silent = false}) {
    _timer?.cancel();
    _timer = null;
    _t0 = null;
    _countInPlan = null;
    _countInSeconds = 0;
    countInNotifier.value = null;
    if (!silent || _state != PlaybackState.stopped) {
      _emitState(PlaybackState.stopped);
      _clearNotifiers();
    }
    onStopped();
  }

  void _tick(Timer _) {
    final d = _data;
    if (d == null || _t0 == null) return;

    final elapsed = DateTime.now().difference(_t0!).inMicroseconds / 1e6;
    final pt = _startOffset + elapsed;

    // Still counting in: the time cursor is behind the first note, so nothing
    // sounds and nothing advances — only the count itself moves on. The
    // highlight already sits on the note we're counting towards (set in [play]),
    // which is what makes the count read as leading into it.
    final plan = _countInPlan;
    if (plan != null && _countInBeatSeconds > 0 && pt < _startOffset) {
      final elapsedInCount = _countInSeconds - (_startOffset - pt);
      final index = (elapsedInCount ~/ _countInBeatSeconds)
          .clamp(0, plan.labels.length - 1);
      if (countInNotifier.value?.index != index) {
        countInNotifier.value =
            (labels: plan.labels, index: index, startMeasure: _fromMeasure);
      }
      return;
    }
    if (countInNotifier.value != null) countInNotifier.value = null;

    // Advance highlight pointer forward
    final events = d.highlightEvents;
    if (events.isNotEmpty) {
      while (_hlPointer + 1 < events.length &&
             events[_hlPointer + 1].onsetSeconds <= pt) {
        _hlPointer++;
      }
      final ev = events[_hlPointer];
      if (ev.measureNumber != _lastEmittedMeasure) {
        notifierForMeasure(_lastEmittedMeasure).value = null;
        _lastEmittedMeasure = ev.measureNumber;
        currentMeasureNotifier.value = ev.measureNumber;
      }
      notifierForMeasure(ev.measureNumber).value = ev.noteIndex;
      currentHighlightNotifier.value = ev;
    }

    // Check loop / end. End time = onset of the measure AFTER the selection end
    // (toMeasure), or the piece end. Map toMeasure (a Measure.number) to its
    // array index first, then advance one — never assume number == index. Bind to
    // the FIRST occurrence of toMeasure at or after the play start, so a range
    // inside a repeated strain stops after that pass (and, with loop on, repeats
    // just the selection) instead of running on through every repeat pass.
    final onsets = d.measureOnsetSeconds;
    final int toIdx;
    if (_toMeasure == null) {
      toIdx = onsets.length - 1;
    } else {
      final startIdx = d.indexOfMeasure(_fromMeasure);
      toIdx = d.measureNumbers.indexOf(_toMeasure!, startIdx >= 0 ? startIdx : 0);
    }
    final endIdx = (toIdx >= 0 ? toIdx : onsets.length - 1) + 1;
    final endT = endIdx < onsets.length ? onsets[endIdx] : d.totalDurationSeconds;
    if (pt >= endT) {
      if (loopEnabled) {
        play(fromMeasure: _fromMeasure, toMeasure: _toMeasure);
      } else {
        _stopInternal();
      }
      return;
    }

    onTick(pt, d);
  }

  int _findPointer(List<HighlightEvent> events, double fromSeconds) {
    int lo = 0, hi = events.length - 1;
    int result = 0;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (events[mid].onsetSeconds <= fromSeconds) {
        result = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return result;
  }

  void _clearNotifiers() {
    for (final n in _measureNotifiers.values) n.value = null;
    currentMeasureNotifier.value = null;
    currentHighlightNotifier.value = null;
  }

  void _disposeAndClearNotifiers() {
    for (final n in _measureNotifiers.values) n.dispose();
    _measureNotifiers.clear();
    currentMeasureNotifier.value = null;
    currentHighlightNotifier.value = null;
  }

  void _emitState(PlaybackState s) {
    if (_state != s) {
      _state = s;
      _stateCtrl.add(s);
    }
  }

  // --- Overridden by platform implementations ---

  /// Called when play() begins; subclass starts audio output.
  void onPlayStarted(MidiData data, double startOffsetSeconds);

  /// Called when playback stops or pauses; subclass silences audio.
  void onStopped();

  /// Called every 40ms while playing; subclass triggers note on/off as needed.
  void onTick(double playbackTime, MidiData data);

  void dispose() {
    _timer?.cancel();
    for (final n in _measureNotifiers.values) n.dispose();
    currentMeasureNotifier.dispose();
    currentHighlightNotifier.dispose();
    countInNotifier.dispose();
    _stateCtrl.close();
  }
}
