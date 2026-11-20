import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:flutter_midi_pro/flutter_midi_pro.dart';
import 'package:flutter_midi_pro/flutter_midi_pro_platform_interface.dart';
import 'audio_output.dart';
import 'bundled_asset_path.dart';
import 'media_transport.dart';
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
      MediaTransport.anyPlaying.addListener(_onRecordingPlaying);
    }
    _initMidi();
  }

  @override
  void dispose() {
    AudioOutput.route.removeListener(_onRouteChanged);
    MediaTransport.anyPlaying.removeListener(_onRecordingPlaying);
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

  /// A recording stopped: catch up on a speaker change made while it played.
  void _onRecordingPlaying() {
    if (!MediaTransport.anyPlaying.value) unawaited(_followSpeaker());
  }

  /// Rebuilds the synth if the speaker has changed since it was built.
  /// Safe to call at any time; concurrent calls share one rebuild.
  ///
  /// Not while a recording plays: synth engines started while an AVPlayer
  /// held an AirPlay speaker's single stream never reached it, and stayed
  /// silent with no engine reset to say so. The rebuild waits for the
  /// recording to stop ([_onRecordingPlaying]); until then [_builtFor] still
  /// names the old speaker, so calibration's own check catches it too.
  Future<void> _followSpeaker() async {
    while (_rebuilding != null) {
      await _rebuilding;
    }
    if (MediaTransport.anyPlaying.value) {
      debugPrint('[playback] speaker changed during a recording; '
          'rebuilding the synth once it stops');
      _nativeAudio
          .invokeMethod<void>('mark', 'synth: rebuild deferred (recording playing)')
          .catchError((_) {});
      return;
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
            await rootBundle.loadString('assets/engine/lookup_tables/midi_patch.json'),
          ) as Map<String, dynamic>;
      _program = j['violin'] as int;
      _velocity = j['noteVelocity'] as int? ?? 90;
      final sfPath = j['soundfontAsset'] as String;
      // Loaded by path where the platform has one, not with
      // loadSoundfontAsset: that copies into the cache under the bare file
      // name and reuses whatever is there, so devices went on loading the old
      // 31 MB bank after the 0.9 MB subset replaced it (bundled_asset_path_io).
      final sfFile = await bundledAssetPath(sfPath);
      _sfId = sfFile != null
          ? await FlutterMidiProPlatform.instance.loadSoundfont(sfFile, 0, _program)
          : await _midi.loadSoundfontAsset(
              assetPath: sfPath, bank: 0, program: _program);
      debugPrint('[midi] soundfont ${sfFile ?? '$sfPath (copied)'}');
      await _midi.selectInstrument(
          sfId: _sfId!, channel: _channel, bank: 0, program: _program);
      _midiReady = true;
      _builtFor = _routeKey(await AudioOutput.fetchRoute());
    } catch (e) {
      // Playback stays disabled, but say so: a wrong soundfontAsset path once
      // made the synth silent for a day with nothing in the log.
      debugPrint('[midi] soundfont failed to load — playback disabled: $e');
    }
  }

  static const _nativeAudio =
      MethodChannel('violin_practice_companion/audio_calibration');

  /// flutter_midi_pro's engines don't restart themselves after an audio
  /// session change, so the synth would go silent: load it afresh.
  @override
  Future<void> restartAudio() async {
    _midiReady = false;
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
    // any count-in: [onTick] only runs once the cursor is within the output
    // latency ([strikeAheadSeconds]) of the start.
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
