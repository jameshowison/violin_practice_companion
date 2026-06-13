import 'dart:async';
import 'package:flutter/foundation.dart';
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

  final Map<int, ValueNotifier<int?>> _measureNotifiers = {};
  final ValueNotifier<int?> currentMeasureNotifier = ValueNotifier(null);
  final ValueNotifier<HighlightEvent?> currentHighlightNotifier = ValueNotifier(null);

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

  void play({int fromMeasure = 1, int? toMeasure}) {
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
    _t0 = DateTime.now();

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

    // Check loop / end. End time = onset of the measure AFTER the last selected
    // one (toMeasure), or the piece end. Map toMeasure (a Measure.number) to its
    // array index first, then advance one — never assume number == index. Use
    // the LAST occurrence so a range spanning a repeated measure plays through
    // every pass rather than stopping at the first.
    final onsets = d.measureOnsetSeconds;
    final toIdx =
        _toMeasure == null ? onsets.length - 1 : d.lastIndexOfMeasure(_toMeasure!);
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
    _stateCtrl.close();
  }
}
