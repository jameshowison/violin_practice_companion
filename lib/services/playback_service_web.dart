import 'dart:js_interop';
import 'dart:math' as math;
import 'playback_service_base.dart';
import 'midi_generator.dart';

// ── Web Audio API JS interop bindings ──────────────────────────────────────

@JS('AudioContext')
@staticInterop
class _AudioContext {
  external factory _AudioContext();
}

extension _AudioContextExt on _AudioContext {
  external double get currentTime;
  // Seconds from a sample leaving the context to it being heard. Not every
  // browser has outputLatency (older Safari), hence the nullable reads.
  external JSNumber? get outputLatency;
  external JSNumber? get baseLatency;
  external JSPromise<JSAny?> resume();
  external _OscillatorNode createOscillator();
  external _GainNode createGain();
  external _AudioDestinationNode get destination;
}

@JS()
@staticInterop
class _AudioNode {}

extension _AudioNodeExt on _AudioNode {
  external void connect(_AudioNode destination);
}

@JS()
@staticInterop
class _AudioDestinationNode extends _AudioNode {}

@JS()
@staticInterop
class _AudioParam {}

extension _AudioParamExt on _AudioParam {
  external set value(double v);
  external void setValueAtTime(double value, double startTime);
  external void linearRampToValueAtTime(double value, double endTime);
  external void exponentialRampToValueAtTime(double value, double endTime);
}

@JS()
@staticInterop
class _OscillatorNode extends _AudioNode {}

extension _OscillatorNodeExt on _OscillatorNode {
  external set type(JSString value);
  external _AudioParam get frequency;
  external void start(double when);
  external void stop(double when);
}

@JS()
@staticInterop
class _GainNode extends _AudioNode {}

extension _GainNodeExt on _GainNode {
  external _AudioParam get gain;
}

// ── PlaybackService (web) ──────────────────────────────────────────────────

class PlaybackService extends PlaybackServiceBase {
  late final _AudioContext _ctx;
  // Each live voice with the context time it ends, so finished ones can be
  // dropped while a long play-through runs.
  final _voices = <(_OscillatorNode, double)>[];

  PlaybackService(super.generator) {
    _ctx = _AudioContext();
  }

  double get _outputLatency =>
      (_ctx.outputLatency ?? _ctx.baseLatency)?.toDartDouble ?? 0;

  /// The moment now being heard, on the context's clock — the clock the
  /// notes are scheduled on — so the highlight, count-in and loop end run
  /// with the sound instead of beside it.
  @override
  double clockNow() => _ctx.currentTime - _outputLatency;

  /// Time to get the first notes into the context before they're due, on
  /// top of the output latency [clockNow] takes off.
  @override
  double get startLookaheadSeconds => 0.1 + _outputLatency;

  @override
  void onPlayStarted(MidiData data, double startOffsetSeconds) {
    _ctx.resume();
    _voices.clear();
    final t0 = playStartClock;
    if (t0 == null) return;
    for (final note in scheduledNotes) {
      final onset = t0 + note.onsetSeconds - startOffsetSeconds;
      if (onset < _ctx.currentTime) continue;
      _scheduleNote(note.midiNote, onset, note.offsetSeconds - note.onsetSeconds);
    }
  }

  void _scheduleNote(int midiNote, double startTime, double duration) {
    final freq = 440.0 * math.pow(2.0, (midiNote - 69) / 12.0).toDouble();
    final osc = _ctx.createOscillator();
    final gain = _ctx.createGain();

    osc.type = 'triangle'.toJS;
    osc.frequency.value = freq;

    // Simple ADSR envelope: fast attack, sustain, short release
    final attack = math.min(0.03, duration * 0.1);
    final releaseStart = startTime + math.max(duration - 0.08, duration * 0.6);

    gain.gain.setValueAtTime(0.0, startTime);
    gain.gain.linearRampToValueAtTime(0.35, startTime + attack);
    gain.gain.setValueAtTime(0.30, releaseStart);
    gain.gain.exponentialRampToValueAtTime(0.001, startTime + duration);

    osc.connect(gain);
    gain.connect(_ctx.destination);

    osc.start(startTime);
    osc.stop(startTime + duration + 0.02);
    _voices.add((osc, startTime + duration + 0.02));
  }

  @override
  void onStopped() {
    final now = _ctx.currentTime;
    for (final (osc, _) in _voices) {
      try {
        osc.stop(now);
      } catch (_) {}
    }
    _voices.clear();
  }

  @override
  void onTick(double playbackTime, MidiData data) {
    // Notes are pre-scheduled via AudioContext; just let go of finished ones.
    final now = _ctx.currentTime;
    _voices.removeWhere((v) => v.$2 < now);
  }
}
