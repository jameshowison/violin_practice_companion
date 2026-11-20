import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which player a sync offset belongs to, and part of its stored key. Only the
/// recording player is left: the rendered score plays through it too. There
/// was a `score` one for the live synth until that was removed (2026-11-20);
/// values stored for it (`audioSyncDelay.score.*`) are ignored.
enum AudioSyncSource { recording }

/// Where audio is currently going, as the OS reports it.
@immutable
class AudioOutputRoute {
  final String portName;

  /// AVAudioSession port type, e.g. `Speaker`, `BluetoothA2DPOutput`,
  /// `AirPlay`, `Headphones`.
  final String portType;

  /// iOS's id for the port. NOT stable for AirPlay across reconnections, so
  /// calibrations are keyed on [speakerKey] instead.
  final String uid;

  /// What a calibration is remembered under: the speaker's type and name,
  /// e.g. `AirPlay|Roam` — the same speaker on Bluetooth is a separate entry,
  /// as its delay is entirely different.
  String get speakerKey =>
      portType.isEmpty && portName.isEmpty ? 'unknown' : '$portType|$portName';
  final double outputLatency;
  final double ioBufferDuration;

  const AudioOutputRoute({
    required this.portName,
    required this.portType,
    required this.uid,
    required this.outputLatency,
    required this.ioBufferDuration,
  });

  factory AudioOutputRoute.fromMap(Map<Object?, Object?> m) {
    double num0(Object? v) => v is num && v.isFinite && v >= 0 ? v.toDouble() : 0;
    return AudioOutputRoute(
      portName: m['portName'] as String? ?? '',
      portType: m['portType'] as String? ?? '',
      uid: m['uid'] as String? ?? '',
      outputLatency: num0(m['outputLatency']),
      ioBufferDuration: num0(m['ioBufferDuration']),
    );
  }

  /// How long after a note is struck it is heard: the port's own latency plus
  /// up to one render buffer. Capped, so a nonsense report can't push the
  /// cursor seconds away from the sound.
  double get latencySeconds =>
      (outputLatency + ioBufferDuration).clamp(0.0, maxLatencySeconds);

  static const maxLatencySeconds = 4.0;

  @override
  String toString() => '$portName ($portType) '
      'latency=${(latencySeconds * 1000).round()}ms '
      '[out=${(outputLatency * 1000).round()} '
      'buf=${(ioBufferDuration * 1000).round()}]';
}

/// The current audio output route, kept fresh by the native side
/// (`ios/Runner/AudioRoutePlugin.swift`), which pushes a report on every route
/// change. On platforms without that plugin — macOS, Android, web, tests —
/// [route] stays null and [latencySeconds] is 0, i.e. no compensation.
///
/// No conditional import is needed: a method channel is platform-neutral, and
/// a missing native side is just a [MissingPluginException].
class AudioOutput {
  AudioOutput._();

  static const _channel =
      MethodChannel('violin_practice_companion/audio_route');

  static final ValueNotifier<AudioOutputRoute?> route = ValueNotifier(null);

  static bool _started = false;

  /// Starts listening; safe to call repeatedly.
  static Future<void> ensureStarted() async {
    if (_started) return;
    _started = true;
    unawaited(_loadCalibrations());
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'routeChanged' && call.arguments is Map) {
        _set(AudioOutputRoute.fromMap(call.arguments as Map));
      }
    });
    try {
      final m = await _channel.invokeMethod<Map<Object?, Object?>>('getRoute');
      if (m != null) _set(AudioOutputRoute.fromMap(m));
    } on MissingPluginException {
      // No native side on this platform: no compensation.
    } on PlatformException catch (e) {
      debugPrint('[audio_route] getRoute failed: $e');
    }
  }

  static void _set(AudioOutputRoute r) {
    final old = route.value;
    route.value = r;
    if (old?.toString() != r.toString()) debugPrint('[audio_route] $r');
  }

  /// Asks the native side for the route now, rather than waiting for a
  /// change to be pushed. Null where there is no native side.
  static Future<AudioOutputRoute?> fetchRoute() async {
    try {
      final m = await _channel.invokeMethod<Map<Object?, Object?>>('getRoute');
      return m == null ? null : AudioOutputRoute.fromMap(m);
    } catch (_) {
      return null;
    }
  }

  /// Seconds between striking a note and hearing it on the current output.
  static double get latencySeconds => route.value?.latencySeconds ?? 0;

  /// Whether [showPicker] can do anything here. A route is only ever reported
  /// where the native side exists, so this is the platform check without a
  /// `Platform.is*`.
  static bool get canPick => route.value != null;

  /// Presents the system output picker (speaker / Bluetooth / AirPlay). The
  /// choice comes back as an ordinary route change. False if there is no
  /// picker on this platform.
  static Future<bool> showPicker() async {
    try {
      return await _channel.invokeMethod<bool>('showPicker') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('[audio_route] showPicker failed: $e');
      return false;
    }
  }

  // ---- Per-speaker measured delay ------------------------------------------
  //
  // iOS's outputLatency is only an estimate, and for a recording AVPlayer
  // already hides some of it, so neither is the delay actually seen. The
  // calibration (SyncCalibrator) measures it with the mic; the result is kept
  // per speaker ([AudioOutputRoute.speakerKey]) and per player, so each speaker remembers its
  // own. Until a speaker is calibrated, iOS's estimate stands in.

  static const _prefPrefix = 'audioSyncDelay.';

  /// Measured delays in ms, by [syncDelayKey]. Listen to rebuild the sheet.
  static final ValueNotifier<Map<String, int>> calibratedDelaysMs =
      ValueNotifier(const {});

  @visibleForTesting
  static String syncDelayKey(AudioSyncSource source, String speaker) =>
      '$_prefPrefix${source.name}.$speaker';

  static Future<void> _loadCalibrations() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final loaded = <String, int>{
        for (final k in prefs.getKeys())
          if (k.startsWith(_prefPrefix) && prefs.get(k) is int)
            k: prefs.getInt(k)!,
      };
      // Anything measured while loading wins over what was on disk.
      calibratedDelaysMs.value = {...loaded, ...calibratedDelaysMs.value};
    } catch (e) {
      debugPrint('[audio_route] loading calibrations failed: $e');
    }
  }

  /// The measured delay for [source] on the current output, in ms, or null
  /// if this speaker hasn't been calibrated.
  static int? calibratedDelayMs(AudioSyncSource source) {
    final r = route.value;
    if (r == null) return null;
    return calibratedDelaysMs.value[syncDelayKey(source, r.speakerKey)];
  }

  /// Stores [ms] as the measured delay for [source] on [on] — the current
  /// output if not given; null forgets it (back to iOS's estimate). Takes
  /// effect at once. A calibration passes the route it STARTED on: by the
  /// time it finishes, the mic has been on and off and the current route may
  /// be a passing one.
  static Future<void> setCalibratedDelayMs(AudioSyncSource source, int? ms,
      {AudioOutputRoute? on}) async {
    final r = on ?? route.value;
    if (r == null) return;
    final key = syncDelayKey(source, r.speakerKey);
    calibratedDelaysMs.value = {...calibratedDelaysMs.value}..remove(key);
    if (ms != null) {
      calibratedDelaysMs.value = {...calibratedDelaysMs.value, key: ms};
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      ms == null ? await prefs.remove(key) : await prefs.setInt(key, ms);
    } catch (_) {
      // Best-effort: the session still holds the value.
    }
  }

  /// Seconds from [source] reaching a moment to it being heard: the measured
  /// delay for this speaker, else nothing. It may be negative (AVPlayer
  /// over-compensating).
  ///
  /// Nothing by default because AVPlayer's position already allows for the
  /// route's reported delay (an Apple media engineer: the player "already
  /// take[s] care of latency"). Subtracting iOS's estimate again counted it
  /// twice — ~2s on AirPlay — and calibrating only papered over that.
  static double heardDelaySeconds(AudioSyncSource source) {
    final ms = calibratedDelayMs(source);
    final s = ms != null ? ms / 1000 : 0.0;
    return s.clamp(-0.5, AudioOutputRoute.maxLatencySeconds);
  }

  // ---- Per-speaker start-up delay -----------------------------------------
  //
  // How long a recording player takes, after Play, to start its clock — which
  // on iOS is the time HEARD (see [heardDelaySeconds]). ~0.15 s on the phone,
  // ~0.6 s on an AirPlay speaker (Kitchen, 2026-11-19). A silent count-in ends
  // on the phone's clock, so it calls Play this much early, or the count's
  // last beat lands that long before the first note. Not something iOS
  // reports, so it is measured on every start (MediaPlaybackService) and
  // kept per speaker.

  static const _startPrefix = 'audioStartDelay.';
  static final Map<String, int> _startDelaysMs = {};
  static bool _startLoaded = false;

  /// The last measured start-up delay on the current output, in seconds;
  /// 0 for a speaker not yet measured.
  static double get startDelaySeconds {
    if (!_startLoaded) unawaited(_loadStartDelays());
    final r = route.value;
    if (r == null) return 0;
    return (_startDelaysMs[r.speakerKey] ?? 0) / 1000;
  }

  /// Records a start-up delay of [seconds] measured on the current output.
  /// Smoothed with the last one, so one slow start (a speaker waking) doesn't
  /// throw the next count off by as much.
  static void recordStartDelay(double seconds) {
    final r = route.value;
    if (r == null || seconds < 0 || seconds > AudioOutputRoute.maxLatencySeconds) {
      return;
    }
    final key = r.speakerKey;
    final ms = (seconds * 1000).round();
    final last = _startDelaysMs[key];
    final next = last == null ? ms : ((last + ms) / 2).round();
    _startDelaysMs[key] = next;
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('$_startPrefix$key', next);
      } catch (_) {}
    }());
  }

  static Future<void> _loadStartDelays() async {
    _startLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in prefs.getKeys()) {
        if (k.startsWith(_startPrefix) && prefs.get(k) is int) {
          // Anything measured while loading wins.
          _startDelaysMs.putIfAbsent(
              k.substring(_startPrefix.length), () => prefs.getInt(k)!);
        }
      }
    } catch (_) {}
  }

  @visibleForTesting
  static void debugSetRoute(AudioOutputRoute? r) => route.value = r;
}
