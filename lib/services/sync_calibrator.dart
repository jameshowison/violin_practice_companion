import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import 'audio_output.dart';
import 'playback_service_base.dart';
import 'sync_calibration.dart';
import 'sync_calibration_clip.dart';

/// Thrown inside a calibration run to stop it with a reason for the user.
class _Failed implements Exception {
  final String reason;
  const _Failed(this.reason);
}

/// Plays the click pattern through ONE player's own sound path while the mic
/// listens, and returns the wall-clock second at which that player sent each
/// click on its way — the moment its cursor treats as "now".
typedef _PlayClicks = Future<List<double>> Function();

/// Measures, per player, how long after it sends a sound that sound is heard
/// on whatever speaker is connected, with the mic listening
/// (`ios/Runner/AudioCalibrationPlugin.swift`). Two players, two delays:
///
/// - **Recordings** — [CalibrationClip] through a just_audio player, timed by
///   its own `position`. That is exactly what `MediaPlaybackService`
///   subtracts from, so whatever AVPlayer already allows for itself is
///   measured away rather than double-counted (531ms on a Sonos Roam over
///   AirPlay, where iOS's estimate over-corrected).
/// - **The synthesized score** — claves struck through the synth
///   (`PlaybackServiceBase.strikeCalibrationClick`), timed by when they were
///   struck. The synth has no such allowance, so its delay is markedly larger
///   on the same speaker: borrowing the recording's put the cursor well
///   ahead of the notes.
class SyncCalibrator {
  static const _channel =
      MethodChannel('violin_practice_companion/audio_calibration');

  /// How long to keep listening after the last click, for it to arrive over
  /// the slowest route (AirPlay).
  static const _tail = Duration(milliseconds: 2600);

  /// Whether the last calibration had to put the app's audio session back
  /// (something else, e.g. the teacher-demo recorder, had changed it) — in
  /// which case the players should be rebuilt on it.
  static bool lastRunChangedSession = false;

  static double _wallNow() => DateTime.now().microsecondsSinceEpoch / 1e6;

  /// Calibrates both players on the current speaker, one after the other
  /// (about 20 seconds), storing each result that succeeds. Anything playing
  /// must be stopped first.
  static Future<({CalibrationResult recording, CalibrationResult score})>
      calibrateAll(PlaybackServiceBase score) async {
    lastRunChangedSession = false;
    final recording = await _withRetry(
        AudioSyncSource.recording, _recordingClicks);
    final synth = await _withRetry(
        AudioSyncSource.score, () => _scoreClicks(score));
    return (recording: recording, score: synth);
  }

  // The first switch to play-and-record after launch could come up deaf — on
  // the simulator it heard none of the clicks, then every one on the next
  // try. So hearing nothing at all earns one automatic retry.
  static Future<CalibrationResult> _withRetry(
      AudioSyncSource source, _PlayClicks play) async {
    final first = await _measure(source, play);
    if (first.ok || first.clicksHeard > 0 || first.clicksPlayed == 0) {
      return first;
    }
    debugPrint('[sync_cal] ${source.name}: heard nothing; retrying once');
    return _measure(source, play);
  }

  /// The recording path: the clip through a just_audio player, each click's
  /// moment read off the player's own position.
  static Future<List<double>> _recordingClicks() async {
    final path = await writeCalibrationClip(CalibrationClip.wavBytes());
    if (path == null) throw const _Failed('not available on this platform');
    final player = AudioPlayer();
    final samples = <(double, double)>[];
    final sampler = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (!player.playing) return;
      final p = player.position.inMicroseconds / 1e6;
      if (p > 0.05) samples.add((_wallNow(), p));
    });
    try {
      await player.setFilePath(path);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      unawaited(player.play());
      await player.processingStateStream
          .firstWhere((s) => s == ProcessingState.completed)
          .timeout(Duration(
              milliseconds:
                  (CalibrationClip.durationSeconds * 1000).round() + 6000));
    } on TimeoutException {
      debugPrint('[sync_cal] timed out: state=${player.processingState} '
          'playing=${player.playing} position=${player.position} '
          'samples=${samples.length}');
      throw const _Failed('the clip never finished playing');
    } finally {
      sampler.cancel();
      await player.dispose();
    }
    final zero = playerZeroWallSeconds(samples);
    if (zero == null) throw const _Failed("couldn't follow the clip's playback");
    return [for (final c in CalibrationClip.clickTimes) zero + c];
  }

  /// The score path: the same pattern struck through the synth, each click's
  /// moment the wall-clock second it was struck — as the score's own notes are.
  static Future<List<double>> _scoreClicks(PlaybackServiceBase score) async {
    if (!await score.prepareCalibrationClick()) {
      throw const _Failed("the score's sound isn't ready");
    }
    const times = CalibrationClip.clickTimes;
    final t0 = _wallNow() + 0.5 - times.first;
    final struck = <double>[];
    for (final c in times) {
      final wait = t0 + c - _wallNow();
      if (wait > 0) {
        await Future<void>.delayed(
            Duration(microseconds: (wait * 1e6).round()));
      }
      struck.add(_wallNow());
      score.strikeCalibrationClick();
    }
    return struck;
  }

  /// One measurement of [source]: mic on, [play] the clicks, listen out the
  /// tail, mic off, compare. Stores the result if it succeeds.
  static Future<CalibrationResult> _measure(
      AudioSyncSource source, _PlayClicks play) async {
    // The speaker being calibrated, taken before the mic re-routes anything.
    final speaker = await AudioOutput.fetchRoute() ?? AudioOutput.route.value;
    await _wakeSpeaker();
    final played = CalibrationClip.clickTimes.length;
    var started = false;
    Map<Object?, Object?>? capture;
    List<double> expected;
    try {
      final Map<Object?, Object?>? info;
      try {
        info = await _channel.invokeMapMethod<Object?, Object?>('start');
        started = true;
      } on PlatformException catch (e) {
        throw _Failed(e.code == 'permission'
            ? 'microphone access is off (Settings › Privacy › Microphone)'
            : "couldn't start the microphone: ${e.message}");
      } on MissingPluginException {
        throw const _Failed('not available on this platform');
      }
      debugPrint('[sync_cal] ${source.name} start $info');
      final before = info?['outputBefore'] as String? ?? '';
      // Switching the mic on can re-route, and the route read straight after
      // can be mid-change. Give it up to 2s to come back to the speaker.
      var after = info?['outputAfter'] as String? ?? '';
      final settleBy = DateTime.now().add(const Duration(seconds: 2));
      while (after != before && DateTime.now().isBefore(settleBy)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        after = (await AudioOutput.fetchRoute())?.portType ?? after;
      }
      if (before.isNotEmpty && after != before) {
        throw _Failed(after.contains('HFP')
            ? 'this speaker switches to call mode when the mic is on'
            : 'the sound moved from $before to $after when the mic came on');
      }
      expected = await play();
      await Future<void>.delayed(_tail);
    } on _Failed catch (f) {
      return CalibrationResult.failed(f.reason, clicksPlayed: played);
    } finally {
      if (started) {
        try {
          capture = await _channel.invokeMapMethod<Object?, Object?>('stop');
        } catch (e) {
          debugPrint('[sync_cal] stop failed: $e');
        }
      }
    }

    final energy = capture?['energy'];
    if (energy is! Float32List) {
      return CalibrationResult.failed('the mic recorded nothing',
          clicksPlayed: played);
    }
    final mic = MicEnvelope(
      startSeconds: (capture!['startWall'] as num).toDouble(),
      hopSeconds: (capture['hop'] as num).toDouble(),
      energy: energy,
    );
    final result = measureDelay(expected, mic);
    var loudest = 0.0;
    for (final e in energy) {
      if (e > loudest) loudest = e;
    }
    debugPrint('[sync_cal] ${source.name} $result '
        'hops=${energy.length} loudest=${loudest.toStringAsExponential(1)} '
        'hostTime=${capture['hostTimeValid']} '
        'drift=${((capture['driftSeconds'] as num? ?? 0) * 1000).toStringAsFixed(1)}ms '
        'inLat=${((capture['inputLatency'] as num? ?? 0) * 1000).round()}ms '
        'speaker=$speaker sessionChanged=${capture['sessionChanged']}');
    if (capture['sessionChanged'] == true) lastRunChangedSession = true;
    if (result.ok) {
      await AudioOutput.setCalibratedDelayMs(
          source, (result.delaySeconds! * 1000).round(),
          on: speaker);
    }
    return result;
  }

  /// Plays a moment of silence in ordinary playback mode, before the mic
  /// comes on. From cold, an AirPlay speaker (a Sonos Roam) didn't play the
  /// clip at all — "never finished" — but calibrated fine straight after
  /// something had played to it. This is that something.
  static Future<void> _wakeSpeaker() async {
    final path = await writeCalibrationClip(
        CalibrationClip.silenceWavBytes(1.5),
        name: 'sync_calibration_wake.wav');
    if (path == null) return;
    final player = AudioPlayer();
    try {
      await player.setFilePath(path);
      unawaited(player.play());
      await player.processingStateStream
          .firstWhere((s) => s == ProcessingState.completed)
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('[sync_cal] wake-up: $e');
    } finally {
      await player.dispose();
    }
  }
}
