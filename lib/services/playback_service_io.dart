import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_midi_pro/flutter_midi_pro.dart';
import 'playback_service_base.dart';
import 'midi_generator.dart';

class PlaybackService extends PlaybackServiceBase {
  final _midi = MidiPro();
  int? _sfId;
  final int _channel = 0;
  int _program = 40;
  int _velocity = 90;
  bool _midiReady = false;

  // Pointers into the sorted notes list for efficient per-tick scheduling
  int _nextOnIdx = 0;
  int _nextOffIdx = 0;
  List<ScheduledNote> _sortedByOffset = [];

  PlaybackService(super.generator) {
    _initMidi();
  }

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
    // Reset sorted offset list and pointers
    _sortedByOffset = List.of(data.notes)
      ..sort((a, b) => a.offsetSeconds.compareTo(b.offsetSeconds));

    // Skip notes that already ended before startOffset
    _nextOnIdx = 0;
    while (_nextOnIdx < data.notes.length &&
        data.notes[_nextOnIdx].onsetSeconds < startOffsetSeconds) {
      _nextOnIdx++;
    }
    _nextOffIdx = 0;
    while (_nextOffIdx < _sortedByOffset.length &&
        _sortedByOffset[_nextOffIdx].offsetSeconds < startOffsetSeconds) {
      _nextOffIdx++;
    }
  }

  @override
  void onStopped() {
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

    // Note-offs before note-ons: prevents outgoing same-pitch note from
    // immediately silencing the newly started note in the same tick.
    while (_nextOffIdx < _sortedByOffset.length &&
        _sortedByOffset[_nextOffIdx].offsetSeconds <= playbackTime) {
      final n = _sortedByOffset[_nextOffIdx];
      _midi.stopNote(sfId: _sfId!, channel: _channel, key: n.midiNote);
      _nextOffIdx++;
    }

    while (_nextOnIdx < data.notes.length &&
        data.notes[_nextOnIdx].onsetSeconds <= playbackTime) {
      final n = data.notes[_nextOnIdx];
      _midi.playNote(
          sfId: _sfId!, channel: _channel, key: n.midiNote, velocity: _velocity);
      _nextOnIdx++;
    }
  }
}
