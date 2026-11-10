import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import 'audio_output.dart';
import 'sync_calibration.dart';
import 'sync_calibration_clip.dart';

/// Measures how long after a recording player reaches a moment that moment is
/// heard, on whatever speaker is connected, by playing [CalibrationClip]
/// through a just_audio player — the same kind of player as a recording —
/// while the mic listens (`ios/Runner/AudioCalibrationPlugin.swift`).
///
/// What comes out is exactly the delay `MediaPlaybackService` subtracts from
/// the player's position, so anything AVPlayer already compensates for itself
/// is measured away rather than double-counted.
class SyncCalibrator {
  static const _channel =
      MethodChannel('violin_practice_companion/audio_calibration');

  /// How long to keep listening after the clip ends, for the last click to
  /// arrive over the slowest route (AirPlay).
  static const _tail = Duration(milliseconds: 2600);

  /// Whether the last calibration had to put the app's audio session back
  /// (something else, e.g. the teacher-demo recorder, had changed it) — in
  /// which case the players should be rebuilt on it.
  static bool lastRunChangedSession = false;

  static double _wallNow() => DateTime.now().microsecondsSinceEpoch / 1e6;

  /// Runs one calibration (about 9 seconds) and, if it succeeds, stores the
  /// result for the current speaker. Anything playing must be stopped first.
  static Future<CalibrationResult> calibrateRecordings() async {
    // The first switch to play-and-record after launch can come up deaf — on
    // the simulator it heard none of the clicks, then every one on the next
    // try. So hearing nothing at all earns one automatic retry.
    final first = await _calibrateOnce();
    if (first.ok || first.clicksHeard > 0 || first.clicksPlayed == 0) {
      return first;
    }
    debugPrint('[sync_cal] heard nothing; retrying once');
    return _calibrateOnce();
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

  static Future<CalibrationResult> _calibrateOnce() async {
    // The speaker being calibrated, taken before the mic re-routes anything.
    final speaker = await AudioOutput.fetchRoute() ?? AudioOutput.route.value;
    await _wakeSpeaker();
    final path = await writeCalibrationClip(CalibrationClip.wavBytes());
    if (path == null) {
      return const CalibrationResult.failed('not available on this platform');
    }
    final played = CalibrationClip.clickTimes.length;
    final player = AudioPlayer();
    final samples = <(double, double)>[];
    Timer? sampler;
    var started = false;
    Map<Object?, Object?>? capture;
    String? failure;
    try {
      final Map<Object?, Object?>? info;
      try {
        info = await _channel.invokeMapMethod<Object?, Object?>('start');
        started = true;
      } on PlatformException catch (e) {
        return CalibrationResult.failed(
            e.code == 'permission'
                ? 'microphone access is off (Settings › Privacy › Microphone)'
                : "couldn't start the microphone: ${e.message}",
            clicksPlayed: played);
      } on MissingPluginException {
        return CalibrationResult.failed('not available on this platform',
            clicksPlayed: played);
      }
      debugPrint('[sync_cal] start $info');
      final before = info?['outputBefore'] as String? ?? '';
      // Switching the mic on re-routes, and the route read straight after can
      // be mid-change. Give it up to 2s to come back to the speaker it was on.
      var after = info?['outputAfter'] as String? ?? '';
      final settleBy = DateTime.now().add(const Duration(seconds: 2));
      while (after != before && DateTime.now().isBefore(settleBy)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        after = (await AudioOutput.fetchRoute())?.portType ?? after;
      }
      debugPrint('[sync_cal] route $before -> $after');
      if (before.isNotEmpty && after != before) {
        failure = after.contains('HFP')
            ? 'this speaker switches to call mode when the mic is on'
            : 'the sound moved from $before to $after when the mic came on';
        return CalibrationResult.failed(failure, clicksPlayed: played);
      }
      // Load the clip on the settled play-and-record route, not the one
      // before it, and give that route a moment more.
      await player.setFilePath(path);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      sampler = Timer.periodic(const Duration(milliseconds: 10), (_) {
        if (!player.playing) return;
        final p = player.position.inMicroseconds / 1e6;
        if (p > 0.05) samples.add((_wallNow(), p));
      });
      unawaited(player.play());
      await player.processingStateStream
          .firstWhere((s) => s == ProcessingState.completed)
          .timeout(Duration(
              milliseconds:
                  (CalibrationClip.durationSeconds * 1000).round() + 6000));
      sampler.cancel();
      await Future<void>.delayed(_tail);
    } on TimeoutException {
      failure = 'the clip never finished playing';
      debugPrint('[sync_cal] timed out: state=${player.processingState} '
          'playing=${player.playing} position=${player.position} '
          'samples=${samples.length}');
    } finally {
      sampler?.cancel();
      if (started) {
        try {
          capture = await _channel.invokeMapMethod<Object?, Object?>('stop');
        } catch (e) {
          debugPrint('[sync_cal] stop failed: $e');
        }
      }
      await player.dispose();
    }
    if (failure != null) {
      return CalibrationResult.failed(failure, clicksPlayed: played);
    }

    final zero = playerZeroWallSeconds(samples);
    final energy = capture?['energy'];
    if (zero == null || energy is! Float32List) {
      return CalibrationResult.failed("couldn't follow the clip's playback",
          clicksPlayed: played);
    }
    final mic = MicEnvelope(
      startSeconds: (capture!['startWall'] as num).toDouble(),
      hopSeconds: (capture['hop'] as num).toDouble(),
      energy: energy,
    );
    final result = measureDelay(
        [for (final c in CalibrationClip.clickTimes) zero + c], mic);
    var loudest = 0.0;
    for (final e in energy) {
      if (e > loudest) loudest = e;
    }
    debugPrint('[sync_cal] $result '
        'hops=${energy.length} loudest=${loudest.toStringAsExponential(1)} '
        'hostTime=${capture['hostTimeValid']} '
        'drift=${((capture['driftSeconds'] as num? ?? 0) * 1000).toStringAsFixed(1)}ms '
        'inLat=${((capture['inputLatency'] as num? ?? 0) * 1000).round()}ms '
        'speaker=$speaker now=${AudioOutput.route.value} '
        'sessionChanged=${capture['sessionChanged']}');
    lastRunChangedSession = capture['sessionChanged'] == true;
    if (result.ok) {
      await AudioOutput.setCalibratedDelayMs(AudioSyncSource.recording,
          (result.delaySeconds! * 1000).round(),
          on: speaker);
    }
    return result;
  }
}
