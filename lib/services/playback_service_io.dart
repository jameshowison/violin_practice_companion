import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
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
      : _outputLatency = outputLatency ?? (() => AudioOutput.latencySeconds) {
    if (outputLatency == null) AudioOutput.ensureStarted();
    _initMidi();
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
    } catch (e) {
      // Soundfont not yet installed; playback silently disabled on mobile
    }
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
