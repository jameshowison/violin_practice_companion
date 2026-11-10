import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:flutter_midi_pro/flutter_midi_pro.dart';
import 'audio_output.dart';
import 'playback_service_base.dart';
import 'midi_generator.dart';

class PlaybackService extends PlaybackServiceBase {
  final _midi = MidiPro();
  int? _sfId;
  final int _channel = 0;
  int _program = 40;
  int _velocity = 90;
  bool _midiReady = false;

  // Pointers into [scheduledNotes] (by onset) and the same notes by offset,
  // for efficient per-tick scheduling.
  int _nextOnIdx = 0;
  int _nextOffIdx = 0;
  List<ScheduledNote> _byOnset = const [];
  List<ScheduledNote> _byOffset = const [];

  /// Seconds between striking a note and hearing it — read live, so a route
  /// change mid-play (connecting a Bluetooth speaker) re-syncs at once.
  final double Function() _outputLatency;

  PlaybackService(super.generator, {double Function()? outputLatency})
      : _outputLatency = outputLatency ??
            (() => AudioOutput.heardDelaySeconds(AudioSyncSource.score)) {
    if (outputLatency == null) {
      AudioOutput.ensureStarted();
      AudioOutput.route.addListener(_onRouteChanged);
    }
    _initMidi();
  }

  @override
  void dispose() {
    AudioOutput.route.removeListener(_onRouteChanged);
    _routeSettle?.cancel();
    super.dispose();
  }

  // --- Following the speaker ------------------------------------------------
  // flutter_midi_pro's engines stay on the output they were built on: switch
  // from the iPad's speaker to an AirPlay speaker and the score plays to
  // nowhere — with no engine configuration change to say so — until the app
  // restarts (Hazel iPad → Kitchen, 2026-11-10; the recording player follows
  // the switch fine). So the synth is rebuilt whenever the speaker differs
  // from the one it was built on.

  /// The output the synth was built on (type, name and iOS's port id — a new
  /// id for the same AirPlay speaker is a reconnection, also worth a rebuild).
  /// Null until known.
  String? _builtFor;
  Timer? _routeSettle;
  Future<void>? _rebuilding;

  static String? _routeKey(AudioOutputRoute? r) =>
      r == null ? null : '${r.portType}|${r.portName}|${r.uid}';

  void _onRouteChanged() {
    // Route reports come in pairs (at once and 0.5s later), and connecting
    // AirPlay can pass through intermediate routes: act once it has settled.
    _routeSettle?.cancel();
    _routeSettle = Timer(const Duration(milliseconds: 800), () {
      unawaited(_followSpeaker());
    });
  }

  /// Rebuilds the synth if the speaker has changed since it was built.
  /// Safe to call at any time; concurrent calls share one rebuild.
  Future<void> _followSpeaker() async {
    while (_rebuilding != null) {
      await _rebuilding;
    }
    final now = _routeKey(AudioOutput.route.value);
    final built = _builtFor;
    if (!_midiReady || now == null) return;
    if (built == null) {
      // Built before the route was known: it was built on this one.
      _builtFor = now;
      return;
    }
    if (now == built) return;
    debugPrint('[playback] speaker changed ($built -> $now); rebuilding synth');
    _nativeAudio
        .invokeMethod<void>('mark', 'synth: speaker changed; rebuilding')
        .catchError((_) {});
    final done = restartAudio();
    _rebuilding = done;
    try {
      await done;
    } finally {
      _rebuilding = null;
    }
  }

  // Notes are struck from [onTick] on wall time, but heard [_outputLatency]
  // later — 10ms on the built-in speaker, ~200ms over Bluetooth, ~2s over
  // AirPlay. So the clock everything runs on is the HEARD moment (as on the
  // web), and notes are struck that far ahead of it.
  @override
  double clockNow() => super.clockNow() - _outputLatency();

  @override
  double get startLookaheadSeconds => _outputLatency();

  @override
  double get strikeAheadSeconds => _outputLatency();

  Future<void> _initMidi() async {
    try {
      final j = jsonDecode(
            await rootBundle.loadString('assets/lookup_tables/midi_patch.json'),
          ) as Map<String, dynamic>;
      _program = j['violin'] as int;
      _velocity = j['noteVelocity'] as int? ?? 90;
      final sfPath = j['soundfontAsset'] as String;
      _sfId = await _midi.loadSoundfontAsset(
          assetPath: sfPath, bank: 0, program: _program);
      await _midi.selectInstrument(
          sfId: _sfId!, channel: _channel, bank: 0, program: _program);
      _midiReady = true;
      _resetsAtLoad = await _engineResets();
      _builtFor = _routeKey(await AudioOutput.fetchRoute());
    } catch (e) {
      // Soundfont not yet installed; playback silently disabled on mobile
    }
  }

  /// flutter_midi_pro's engines don't restart themselves after an audio
  /// session change, so the synth would go silent: load it afresh.
  // The calibration click: claves from the General MIDI drum kit (bank 128),
  // on a channel the score never uses — a sharp attack through the very
  // synth path the notes take, where the violin's own attack is too soft to
  // time.
  static const _clickChannel = 9;
  static const _clickKey = 75;
  bool _clickReady = false;

  // The synth's engines stop on an audio-session reconfiguration and
  // flutter_midi_pro never restarts them (AudioCalibrationPlugin,
  // `engineResets`). The count at load tells whether that has happened since.
  static const _nativeAudio =
      MethodChannel('violin_practice_companion/audio_calibration');
  int? _resetsAtLoad;

  static Future<int?> _engineResets() async {
    try {
      return await _nativeAudio.invokeMethod<int>('engineResets');
    } catch (_) {
      return null; // no such plugin on this platform: nothing to check
    }
  }

  @override
  Future<bool> prepareCalibrationClick() async {
    // On a different speaker from the one it was built on, the synth is
    // silent (see "Following the speaker"); rebuild before striking.
    await _followSpeaker();
    // A silent synth would strike every clave unheard and fail as "heard too
    // few clicks". Check first, and reload it if its engines were stopped.
    final now = await _engineResets();
    final atLoad = _resetsAtLoad;
    if (_midiReady && now != null && atLoad != null && now > atLoad) {
      final msg = 'synth engines reconfigured ${now - atLoad}x since load; '
          'reloading the soundfont';
      debugPrint('[sync_cal] $msg');
      _nativeAudio.invokeMethod<void>('mark', msg).catchError((_) {});
      await restartAudio();
      if (!_midiReady) return false;
    }
    final id = _sfId;
    if (!_midiReady || id == null) return false;
    if (!_clickReady) {
      try {
        await _midi.selectInstrument(
            sfId: id, channel: _clickChannel, bank: 128, program: 0);
        _clickReady = true;
      } catch (e) {
        return false;
      }
    }
    return true;
  }

  @override
  void strikeCalibrationClick() {
    final id = _sfId;
    if (!_clickReady || id == null) return;
    _midi.playNote(
        sfId: id, channel: _clickChannel, key: _clickKey, velocity: 127);
    Future<void>.delayed(const Duration(milliseconds: 80), () {
      if (_sfId == id) {
        _midi.stopNote(sfId: id, channel: _clickChannel, key: _clickKey);
      }
    });
  }

  @override
  Future<void> restartAudio() async {
    _midiReady = false;
    _clickReady = false;
    final id = _sfId;
    _sfId = null;
    if (id != null) {
      try {
        await _midi.unloadSoundfont(id);
      } catch (_) {}
    }
    await _initMidi();
  }

  @override
  void onPlayStarted(MidiData data, double startOffsetSeconds) {
    if (!_midiReady) return;
    // A note tied over into the start bar comes back from the shared schedule
    // struck at the start, so it sounds on the first tick — which comes after
    // any count-in: [onTick] only runs once the cursor reaches the start.
    _byOnset = scheduledNotes;
    _byOffset = List.of(_byOnset)
      ..sort((a, b) => a.offsetSeconds.compareTo(b.offsetSeconds));
    _nextOnIdx = 0;
    _nextOffIdx = 0;
  }

  @override
  void onStopped() => _allNotesOff();

  @override
  void onMuteChanged(bool muted) {
    // Unmuting needs nothing: the next note sounds at its onset.
    if (muted) _allNotesOff();
  }

  void _allNotesOff() {
    if (!_midiReady || _sfId == null) return;
    // Stop all notes on channel
    for (int key = 0; key < 128; key++) {
      try {
        _midi.stopNote(sfId: _sfId!, channel: _channel, key: key);
      } catch (_) {}
    }
  }

  @override
  void onTick(double playbackTime, MidiData data) {
    if (!_midiReady || _sfId == null) return;
    final strikeTime = playbackTime + _outputLatency();

    // Note-offs before note-ons: prevents outgoing same-pitch note from
    // immediately silencing the newly started note in the same tick.
    while (_nextOffIdx < _byOffset.length &&
        _byOffset[_nextOffIdx].offsetSeconds <= strikeTime) {
      final n = _byOffset[_nextOffIdx];
      _midi.stopNote(sfId: _sfId!, channel: _channel, key: n.midiNote);
      _nextOffIdx++;
    }

    while (_nextOnIdx < _byOnset.length &&
        _byOnset[_nextOnIdx].onsetSeconds <= strikeTime) {
      final n = _byOnset[_nextOnIdx];
      // Muted, the pointer still advances so unmuting resumes in place.
      if (!muted) {
        _midi.playNote(
            sfId: _sfId!, channel: _channel, key: n.midiNote, velocity: _velocity);
      }
      _nextOnIdx++;
    }
  }
}
