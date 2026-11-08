import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Where audio is currently going, as the OS reports it.
@immutable
class AudioOutputRoute {
  final String portName;

  /// AVAudioSession port type, e.g. `Speaker`, `BluetoothA2DPOutput`,
  /// `AirPlay`, `Headphones`.
  final String portType;

  /// Stable per-device id — the key a per-speaker calibration would use.
  final String uid;
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

  /// Seconds between striking a note and hearing it on the current output.
  static double get latencySeconds => route.value?.latencySeconds ?? 0;
}
