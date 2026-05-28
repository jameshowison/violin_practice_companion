import 'dart:async';
import '../models/parsed_piece.dart';
import 'midi_generator.dart';

enum PlaybackState { playing, paused, stopped }

/// Shared timing and measure-tracking logic for both platform implementations.
/// Subclasses handle the actual audio output.
abstract class PlaybackServiceBase {
  final MidiGenerator generator;

  MidiData? _data;
  ParsedPiece? _piece;
  int _bpm = 60;

  bool loopEnabled = false;
  PlaybackState _state = PlaybackState.stopped;
  int _currentMeasure = 1;
  int _fromMeasure = 1;
  int? _toMeasure;
  DateTime? _t0;
  double _startOffset = 0.0;
  Timer? _timer;

  final _measureCtrl = StreamController<int?>.broadcast();
  final _stateCtrl = StreamController<PlaybackState>.broadcast();

  Stream<int?> get currentMeasure => _measureCtrl.stream;
  Stream<PlaybackState> get state => _stateCtrl.stream;
  PlaybackState get playbackState => _state;
  int get currentBpm => _bpm;

  PlaybackServiceBase(this.generator);

  Future<void> loadPiece(ParsedPiece piece) async {
    _stopInternal();
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
    _currentMeasure = fromMeasure;
    _startOffset = d.measureOnsetSeconds[fromMeasure - 1];
    _t0 = DateTime.now();
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
    final savedMeasure = _currentMeasure;
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
      _measureCtrl.add(null); // clear active measure highlight
    }
    onStopped();
  }

  void _tick(Timer _) {
    final d = _data;
    if (d == null || _t0 == null) return;

    final elapsed = DateTime.now().difference(_t0!).inMicroseconds / 1e6;
    final pt = _startOffset + elapsed;

    // Advance current measure pointer
    final onsets = d.measureOnsetSeconds;
    int newMeasure = _fromMeasure;
    for (int i = _fromMeasure - 1; i < onsets.length; i++) {
      if (onsets[i] <= pt) {
        newMeasure = i + 1;
      } else {
        break;
      }
    }
    if (newMeasure != _currentMeasure) {
      _currentMeasure = newMeasure;
      _measureCtrl.add(newMeasure);
    }

    // Check loop / end
    final endM = _toMeasure ?? onsets.length;
    final endT = endM < onsets.length ? onsets[endM] : d.totalDurationSeconds;
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
    _measureCtrl.close();
    _stateCtrl.close();
  }
}
