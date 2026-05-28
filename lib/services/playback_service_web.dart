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
  final _oscillators = <_OscillatorNode>[];

  PlaybackService(super.generator) {
    _ctx = _AudioContext();
  }

  @override
  void onPlayStarted(MidiData data, double startOffsetSeconds) {
    _oscillators.clear();
    // 100ms lookahead so notes don't clip at the very start
    final audioT0 = _ctx.currentTime + 0.1;
    for (final note in data.notes) {
      if (note.offsetSeconds <= startOffsetSeconds) continue;
      final onset = audioT0 + (note.onsetSeconds - startOffsetSeconds);
      final dur = note.offsetSeconds - note.onsetSeconds;
      if (onset < _ctx.currentTime) continue;
      _scheduleNote(note.midiNote, onset, dur);
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
    _oscillators.add(osc);
  }

  @override
  void onStopped() {
    final now = _ctx.currentTime;
    for (final osc in _oscillators) {
      try {
        osc.stop(now);
      } catch (_) {}
    }
    _oscillators.clear();
  }

  @override
  void onTick(double playbackTime, MidiData data) {
    // Notes are pre-scheduled via AudioContext; no per-tick work needed.
  }
}
