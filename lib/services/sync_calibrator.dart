import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import 'audio_output.dart';
import 'media_transport.dart';
import 'package:score_sync/score_sync.dart';
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

/// Measures how long after the recording player reaches a sound that sound
/// is heard on whatever speaker is connected, with the mic listening
/// (`ios/Runner/AudioCalibrationPlugin.swift`): [CalibrationClip] through the
/// player recordings play through (on iOS the native one, [NativeTransport]),
/// timed by its own clock. That is exactly what `MediaPlaybackService`
/// subtracts from — for recordings and the rendered score alike, which plays
/// through the same player.
///
/// Through the native player it measures ~10ms on the iPad speaker and on
/// AirPlay (a Sonos Roam, Kitchen; 2026-11-18/20): AVPlayer's position
/// already is what is heard. The 531–584ms once measured here on AirPlay was
/// just_audio's Dart-side position, which on iOS extrapolates from the last
/// event it was sent; its `play` updates the native position without sending
/// one, so the Dart clock ran ahead of the player. A calibration stored from
/// then still holds the cursor ~0.6 s behind the sound until redone (the
/// Roam on Hazel iPad, until 2026-11-20).
///
/// There was a second half, for the live synth: claves struck through it and
/// timed by when they were struck. It went with the rendered score (docs/
/// rendered-score-plan.md, phase 4): the synth's engines don't follow a
/// switch to AirPlay, so on the speaker that most needed it, it was heard
/// 0 of 10 times (Hazel iPad + the Roam, 2026-11-20). The live synth itself
/// went in phase 6, the same day.
class SyncCalibrator {
  static const _channel =
      MethodChannel('violin_practice_companion/audio_calibration');

  /// How long to keep listening after the last click, for it to arrive over
  /// the slowest route (AirPlay).
  static const _tail = Duration(milliseconds: 2600);

  /// Whether the last calibration had to put the app's audio session back
  /// (something else, e.g. the teacher-demo recorder, had changed it) — in
  /// which case the players should be rebuilt on it. Before
  /// `configureAppAudioSession` this was true on nearly every run: just_audio's
  /// first play() had switched the session to `.playback` behind our back.
  static bool lastRunChangedSession = false;

  static double _wallNow() => DateTime.now().microsecondsSinceEpoch / 1e6;

  // Diagnostic trace (AudioCalibrationPlugin.swift, "Trace"): every volume,
  // route and engine change across a whole calibration, with the step it
  // happened in. Printed as `[sync_cal trace]` lines when the run ends.
  static Future<void> _traceStart() async {
    try {
      await _channel.invokeMethod<void>('traceStart');
    } catch (_) {}
  }

  /// Not awaited, so it doesn't shift the timing it is marking; the channel
  /// keeps the calls in order.
  static void _mark(String label) {
    _channel.invokeMethod<void>('mark', label).catchError((_) {});
  }

  static Future<void> _traceStop() async {
    final List<Object?>? events;
    try {
      events = await _channel.invokeListMethod<Object?>('traceStop');
    } catch (_) {
      return;
    }
    if (events == null || events.isEmpty) return;
    final t0 = ((events.first as Map)['t'] as num).toDouble();
    for (final e in events.cast<Map<Object?, Object?>>()) {
      final ms = ((e['t'] as num).toDouble() - t0) * 1000;
      debugPrint('[sync_cal trace] +${ms.round().toString().padLeft(6)}ms '
          '${e['kind']} ${e['detail']}');
    }
  }

  /// Calibrates the recording player on the current speaker (about 10
  /// seconds), storing the result if it succeeds. Anything playing must be
  /// stopped first.
  static Future<CalibrationResult> calibrate() async {
    lastRunChangedSession = false;
    await _traceStart();
    try {
      _mark('recording phase');
      return await _withRetry(AudioSyncSource.recording, _recordingClicks);
    } finally {
      await _traceStop();
    }
  }

  // The first switch to play-and-record after launch could come up deaf — on
  // the simulator it heard none of the clicks, then every one on the next
  // try. (That was when just_audio's first play() still left the session in
  // .playback, so every mic start switched it back; now it rarely switches.)
  // So hearing nothing at all earns one automatic retry.
  static Future<CalibrationResult> _withRetry(
      AudioSyncSource source, _PlayClicks play) async {
    final first = await _measure(source, play);
    if (first.ok || first.clicksHeard > 0 || first.clicksPlayed == 0) {
      return first;
    }
    debugPrint('[sync_cal] ${source.name}: heard nothing; retrying once');
    return _measure(source, play);
  }

  /// The recording path: the clip through the player recordings play
  /// through, each click's moment read off that player's own position.
  ///
  /// On iOS that is the native player ([NativeTransport]), whose position
  /// and wall-clock stamp are read together natively, so what this measures
  /// is the route's delay beyond what AVPlayer already allows for — the same
  /// clock the highlight and the video picture follow. just_audio elsewhere.
  static Future<List<double>> _recordingClicks() async {
    final path = await writeCalibrationClip(CalibrationClip.wavBytes());
    if (path == null) throw const _Failed('not available on this platform');
    final native = await NativeTransport.open(path, picture: false);
    if (native != null) return _nativeRecordingClicks(native);
    final player = AudioPlayer();
    final samples = <(double, double)>[];
    final sampler = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (!player.playing) return;
      final p = player.position.inMicroseconds / 1e6;
      if (p > 0.05) samples.add((_wallNow(), p));
    });
    try {
      _mark('clip setFilePath');
      await player.setFilePath(path);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      _mark('clip play');
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
      _mark('clip done; disposing player');
      await player.dispose();
      _mark('clip player disposed');
    }
    final zero = playerZeroWallSeconds(samples);
    if (zero == null) throw const _Failed("couldn't follow the clip's playback");
    return [for (final c in CalibrationClip.clickTimes) zero + c];
  }

  static Future<List<double>> _nativeRecordingClicks(
      NativeTransport player) async {
    final samples = <(double, double)>[];
    var sampling = true;
    Future<void> sample() async {
      while (sampling) {
        final c = await player.clock();
        if (c != null && c.rate > 0 && c.positionSec > 0.05) {
          samples.add((c.wallSec, c.positionSec));
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    try {
      _mark('clip native load');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      _mark('clip play');
      final sampler = sample();
      final done = player.changes.firstWhere((_) => player.completed);
      await player.play();
      try {
        await done.timeout(Duration(
            milliseconds:
                (CalibrationClip.durationSeconds * 1000).round() + 6000));
      } on TimeoutException {
        debugPrint('[sync_cal] native clip timed out: '
            'position=${player.position} samples=${samples.length}');
        throw const _Failed('the clip never finished playing');
      } finally {
        sampling = false;
        await sampler;
      }
    } finally {
      _mark('clip done; disposing player');
      await player.dispose();
      _mark('clip player disposed');
    }
    final zero = playerZeroWallSeconds(samples);
    if (zero == null) throw const _Failed("couldn't follow the clip's playback");
    _mark('clip zero from ${samples.length} native clock reads');
    return [for (final c in CalibrationClip.clickTimes) zero + c];
  }

  /// One measurement of [source]: mic on, [play] the clicks, listen out the
  /// tail, mic off, compare. Stores the result if it succeeds.
  static Future<CalibrationResult> _measure(
      AudioSyncSource source, _PlayClicks play) async {
    // The speaker being calibrated, taken before the mic re-routes anything.
    final speaker = await AudioOutput.fetchRoute() ?? AudioOutput.route.value;
    final played = CalibrationClip.clickTimes.length;
    _mark('${source.name}: wake-up');
    if (!await _wakeSpeaker()) {
      const reason = "the speaker isn't responding yet — try again";
      _mark('${source.name} RESULT failed: $reason');
      return CalibrationResult.failed(reason, clicksPlayed: played);
    }
    _mark('${source.name}: mic start');
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
      _mark('${source.name}: playing clicks');
      expected = await play();
      await Future<void>.delayed(_tail);
      _mark('${source.name}: tail done');
    } on _Failed catch (f) {
      _mark('${source.name} RESULT failed: ${f.reason}');
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
    _mark('${source.name} RESULT $result '
        'loudest=${loudest.toStringAsExponential(1)} '
        'sessionChanged=${capture['sessionChanged']}');
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

  /// Plays a moment of silence before the mic comes on (in the same
  /// play-and-record session; only the mic is off). From cold, an AirPlay
  /// speaker (a Sonos Roam) didn't play the clip at all — "never finished" —
  /// but calibrated fine straight after something had played to it. This is
  /// that something.
  ///
  /// The silence must actually finish playing. On 2026-11-18 (Hazel iPad, an
  /// AirPlay speaker, straight after a video) it never did — the 8s timeout
  /// passed, the clicks went out anyway, the clip stalled ~2s at its start and
  /// half of them were never heard. The same timeout preceded every failed
  /// AirPlay run in the trace. A stuck player is thrown away and the silence
  /// played again on a fresh one, a few times; false if none ever finished.
  static Future<bool> _wakeSpeaker() async {
    final path = await writeCalibrationClip(
        CalibrationClip.silenceWavBytes(1.5),
        name: 'sync_calibration_wake.wav');
    if (path == null) return true; // nothing to wake with; measure anyway
    for (var attempt = 1; attempt <= 3; attempt++) {
      // The same player the clip will go through, where there is one.
      final native = await NativeTransport.open(path, picture: false);
      if (native != null) {
        _mark('wake play (try $attempt, native)');
        try {
          final done = native.changes.firstWhere((_) => native.completed);
          await native.play();
          await done.timeout(const Duration(seconds: 5));
          _mark('wake done');
          return true;
        } catch (e) {
          _mark('wake timeout (try $attempt)');
          debugPrint('[sync_cal] wake-up try $attempt: $e');
        } finally {
          await native.dispose();
        }
        continue;
      }
      final player = AudioPlayer();
      try {
        await player.setFilePath(path);
        _mark('wake play (try $attempt)');
        unawaited(player.play());
        await player.processingStateStream
            .firstWhere((s) => s == ProcessingState.completed)
            .timeout(const Duration(seconds: 5));
        _mark('wake done');
        return true;
      } catch (e) {
        _mark('wake timeout (try $attempt)');
        debugPrint('[sync_cal] wake-up try $attempt: $e');
      } finally {
        await player.dispose();
      }
    }
    return false;
  }
}
