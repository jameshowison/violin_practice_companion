import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pitch_tuner/pitch_tuner.dart';

import 'drone_player.dart';

/// [DronePlayerBase] on just_audio: each pitch rendered once into
/// `<cache>/drone_tones/`, then played with [LoopMode.one]. The buffer holds
/// a whole number of cycles, so the loop has no seam to hear.
///
/// The app's audio session is configured in `main()`
/// (app_audio_session.dart) before anything plays, so this leaves it alone.
class DronePlayer implements DronePlayerBase {
  AudioPlayer? _player;

  /// Bumped by every play and stop, so a slow render or fade that has been
  /// overtaken gives way.
  int _gen = 0;
  double? _hz;

  static const _fadeIn = Duration(milliseconds: 180);
  static const _fadeOut = Duration(milliseconds: 120);

  @override
  Future<void> play(double hz) async {
    final gen = ++_gen;
    try {
      final path = await _file(hz);
      if (gen != _gen) return;
      final player = _player ??= AudioPlayer();
      if (_hz != hz || player.processingState == ProcessingState.idle) {
        if (player.playing) await _fade(player, 1, 0, _fadeOut, gen);
        if (gen != _gen) return;
        await player.setVolume(0);
        await player.setLoopMode(LoopMode.one);
        await player.setFilePath(path);
        _hz = hz;
      }
      if (gen != _gen) return;
      // Not awaited: play() completes only when playback stops.
      unawaited(player.play());
      await _fade(player, player.volume, 1, _fadeIn, gen);
      if (kDebugMode) debugPrint('[drone] ${hz.toStringAsFixed(2)} Hz');
    } catch (e) {
      if (kDebugMode) debugPrint('[drone] play failed: $e');
    }
  }

  @override
  Future<void> stop() async {
    final gen = ++_gen;
    final player = _player;
    if (player == null || !player.playing) return;
    try {
      await _fade(player, player.volume, 0, _fadeOut, gen);
      if (gen != _gen) return;
      await player.pause();
      if (kDebugMode) debugPrint('[drone] stopped');
    } catch (e) {
      if (kDebugMode) debugPrint('[drone] stop failed: $e');
    }
  }

  @override
  Future<void> dispose() async {
    ++_gen;
    final player = _player;
    _player = null;
    _hz = null;
    await player?.dispose();
  }

  /// A short volume ramp, in a few steps. (AVPlayer's volume is ignored on
  /// AirPlay, where the tone simply starts and stops.)
  Future<void> _fade(AudioPlayer p, double from, double to, Duration over, int gen) async {
    const steps = 6;
    for (var i = 1; i <= steps; i++) {
      if (gen != _gen) return;
      await p.setVolume(from + (to - from) * i / steps);
      await Future<void>.delayed(over ~/ steps);
    }
  }

  /// The rendered tone for [hz], written the first time it is asked for.
  static Future<String> _file(double hz) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/drone_tones');
    final file = File('${dir.path}/drone_${hz.toStringAsFixed(3)}.wav');
    if (await file.exists()) return file.path;
    await dir.create(recursive: true);
    final tone = DroneTone.render(hz);
    // Written beside, then renamed, so a half-written file is never played.
    final part = File('${file.path}.part');
    await part.writeAsBytes(tone.toWav(), flush: true);
    await part.rename(file.path);
    if (kDebugMode) {
      debugPrint('[drone] rendered ${file.path} (${tone.hz.toStringAsFixed(3)} Hz)');
    }
    return file.path;
  }
}
