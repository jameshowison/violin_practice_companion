import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

/// The player behind a [MediaPlaybackService]: the few things it asks of one.
///
/// Two of them. [NativeTransport] is one native AVPlayer (iOS,
/// ios/Runner/VideoTransportPlugin.swift) for every recording that is a file:
/// a video's sound AND picture, so nothing else opens the file to show the
/// picture, and an audio file's sound — one clock for all of them, the same
/// one the speaker calibration measures through. [JustAudioTransport] is the
/// rest: bundled assets, and every medium on Android.
///
/// That matters on an AirPlay speaker, which takes one audio stream at a time:
/// with a second, muted player showing the picture, the speaker took the sound
/// and the picture never moved (Hazel iPad + a Sonos, 2026-11-18).
abstract class MediaTransport {
  /// Whether any recording player is playing right now — calibration's
  /// included. The synth defers rebuilding for a new speaker until this is
  /// false: its engines, started while an AVPlayer held an AirPlay speaker's
  /// one stream, never reached the speaker, and stayed silent with nothing to
  /// say so (Hazel iPad + Kitchen, switched mid-play, 2026-11-18).
  static final ValueNotifier<bool> anyPlaying = ValueNotifier(false);
  static final Set<Object> _playing = {};

  /// Counts the Plays a player gave up on because the speaker wouldn't take
  /// the sound — a stale AirPlay connection, after ~2 h idle (Jamz + Kitchen,
  /// 2026-11-20). The tray listens and offers the speaker picker: picking the
  /// speaker again is the one cure seen to work, and the app can't do it
  /// itself (VideoTransportPlugin.swift, `itemFailed`).
  static final ValueNotifier<int> speakerFailures = ValueNotifier(0);

  static void _setPlaying(Object player, bool playing) {
    playing ? _playing.add(player) : _playing.remove(player);
    anyPlaying.value = _playing.isNotEmpty;
  }

  /// Gives the player its file, stopping by itself at [end] (null: the
  /// file's end), positioned at [initialPosition].
  Future<void> setSource(
      {String? asset, String? file, Duration? end, Duration? initialPosition});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// [seek], for a start after the player has played to its end (a loop
  /// going round, Play again after a stop at the selection's end): on iOS a
  /// FRESH copy of the item is sought, because seeking the ended one and
  /// playing at once stalled AVPlayer on AirPlay for ~10 s, every few passes,
  /// recordings and rendered score alike (VideoTransportPlugin.swift,
  /// `seekFresh`). A plain seek elsewhere.
  Future<void> seekFresh(Duration position);
  Future<void> setSpeed(double speed);

  /// Where the player has got to — not what is heard (see
  /// `MediaPlaybackService.heardAudioPosition`).
  Duration get position;
  Duration? get duration;

  /// Whether Play is in force: stays true at a completion until [pause], as
  /// just_audio's does.
  bool get playing;

  /// Stopped at the end (the file's, or the [setSource] end).
  bool get completed;

  /// Gave up on this Play: the sound couldn't be got to the speaker, even
  /// after retrying (see [speakerFailures]). Cleared by the next [play].
  bool get failed;

  /// Fires whenever [playing] or [completed] may have changed.
  Stream<void> get changes;

  /// The picture, for a transport that has one.
  ValueListenable<VideoPicture?> get picture;

  Future<void> dispose();
}

/// A texture to show and how to show it.
@immutable
class VideoPicture {
  final int textureId;
  final double width, height;

  /// Clockwise degrees the frames need turning (a portrait phone capture).
  final int rotation;

  const VideoPicture(this.textureId, this.width, this.height, this.rotation);

  bool get _sideways => rotation == 90 || rotation == 270;
  double get aspectRatio {
    final w = _sideways ? height : width, h = _sideways ? width : height;
    return w > 0 && h > 0 ? w / h : 16 / 9;
  }
}

class JustAudioTransport implements MediaTransport {
  final AudioPlayer _player = AudioPlayer();
  static final ValueNotifier<VideoPicture?> _noPicture = ValueNotifier(null);

  @override
  Future<void> setSource(
      {String? asset, String? file, Duration? end, Duration? initialPosition}) {
    final UriAudioSource source =
        asset != null ? AudioSource.asset(asset) : AudioSource.file(file!);
    return _player.setAudioSource(
        end == null ? source : ClippingAudioSource(child: source, end: end),
        initialPosition: initialPosition);
  }

  @override
  Future<void> play() {
    MediaTransport._setPlaying(this, true);
    return _player.play();
  }

  @override
  Future<void> pause() {
    MediaTransport._setPlaying(this, false);
    return _player.pause();
  }
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> seekFresh(Duration position) => _player.seek(position);
  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);
  @override
  Duration get position => _player.position;
  @override
  Duration? get duration => _player.duration;
  @override
  bool get playing => _player.playing;
  @override
  bool get completed => _player.processingState == ProcessingState.completed;
  @override
  bool get failed => false;
  @override
  Stream<void> get changes => _player.playerStateStream;
  @override
  ValueListenable<VideoPicture?> get picture => _noPicture;
  @override
  Future<void> dispose() {
    MediaTransport._setPlaying(this, false);
    return _player.dispose();
  }
}

/// One native AVPlayer for a file's sound, and its picture if it has one.
/// Create with [NativeTransport.open]; null where the platform has no such
/// player.
class NativeTransport implements MediaTransport {
  static const _channel = MethodChannel('vpc/video_transport');
  static const _events = EventChannel('vpc/video_transport/events');
  static Stream<Map<Object?, Object?>>? _eventStream;

  final int _id;
  final Duration _duration;
  final ValueNotifier<VideoPicture?> _picture;
  final _changes = StreamController<void>.broadcast();
  late final StreamSubscription<Map<Object?, Object?>> _sub;

  // The timeline as last reported, extrapolated between reports: a position
  // and the wall-clock moment it was read, both natively (microseconds).
  int _snapUs = 0;
  double _snapRate = 0;
  int _snapWallUs = 0;
  int? _endMs;
  bool _playing = false;
  bool _completed = false;
  bool _failed = false;
  double _speed = 1;
  bool _disposed = false;
  // Seeks sent and not yet answered. An event the player sent before a seek
  // landed can arrive after it was asked for, still saying "completed, at
  // the end": taken as news, a loop's seek back to its start read as a
  // second end, and the loop restarted twice in 16 ms, which wedged AVPlayer
  // on AirPlay (Jamz + Kitchen, 2026-11-19). So events wait for the seek.
  int _seeksInFlight = 0;

  NativeTransport._(this._id, this._duration, VideoPicture? picture)
      : _picture = ValueNotifier(picture) {
    _sub = _eventStream!.where((e) => e['id'] == _id).listen(_onEvent);
  }

  /// Opens [path] — with its picture, if [picture] and it has one — or null
  /// when this platform has no native transport (Android today); the caller
  /// keeps just_audio.
  static Future<NativeTransport?> open(String path,
      {bool picture = true}) async {
    final Map<Object?, Object?>? info;
    try {
      _eventStream ??= _events
          .receiveBroadcastStream()
          .map((e) => (e as Map).cast<Object?, Object?>())
          .asBroadcastStream();
      info = await _channel
          .invokeMapMethod<Object?, Object?>(
              'create', {'path': path, 'picture': picture});
    } on MissingPluginException {
      return null;
    }
    if (info == null) return null;
    final textureId = info['textureId'] as int? ?? -1;
    return NativeTransport._(
      info['id'] as int,
      Duration(milliseconds: info['durationMs'] as int? ?? 0),
      textureId < 0
          ? null
          : VideoPicture(
              textureId,
              (info['width'] as num? ?? 0).toDouble(),
              (info['height'] as num? ?? 0).toDouble(),
              info['rotation'] as int? ?? 0,
            ),
    );
  }

  int get _nowUs => DateTime.now().microsecondsSinceEpoch;

  /// The player's position and the wall-clock second it was read at, both
  /// taken natively in one go — no channel latency between them. For the
  /// calibration, which needs to know exactly when the clip's clicks left.
  Future<({double positionSec, double wallSec, double rate})?> clock() async {
    if (_disposed) return null;
    final c = await _channel
        .invokeMapMethod<Object?, Object?>('clock', {'id': _id});
    if (c == null || c['wallUs'] == null) return null;
    return (
      positionSec: (c['positionUs'] as int) / 1e6,
      wallSec: (c['wallUs'] as int) / 1e6,
      rate: (c['rate'] as num).toDouble(),
    );
  }

  void _onEvent(Map<Object?, Object?> e) {
    if (_seeksInFlight > 0) return;
    _snapUs = e['positionUs'] as int? ?? _snapUs;
    _snapRate = (e['rate'] as num? ?? 0).toDouble();
    _snapWallUs = e['wallUs'] as int? ?? _nowUs;
    final completed = e['completed'] == true;
    if (completed != _completed) {
      _completed = completed;
      _changes.add(null);
    }
    final failed = e['failed'] == true;
    if (failed != _failed) {
      _failed = failed;
      if (failed) MediaTransport.speakerFailures.value++;
      _changes.add(null);
    }
  }

  void _setSnap(int us, double rate) {
    _snapUs = us;
    _snapRate = rate;
    _snapWallUs = _nowUs;
  }

  Future<void> _call(String method, [Map<String, Object?> args = const {}]) {
    if (_disposed) return Future.value();
    return _channel.invokeMethod<void>(method, {'id': _id, ...args});
  }

  @override
  Future<void> setSource(
      {String? asset, String? file, Duration? end, Duration? initialPosition}) async {
    // The file is fixed at [open]; only the end and the position move.
    _endMs = end?.inMilliseconds;
    await _call('setEnd', {'ms': _endMs});
    if (initialPosition != null) await seek(initialPosition);
  }

  @override
  Future<void> play() async {
    _playing = true;
    MediaTransport._setPlaying(this, true);
    _completed = false;
    _failed = false;
    _changes.add(null);
    await _call('play', {'rate': _speed});
  }

  @override
  Future<void> pause() async {
    _playing = false;
    MediaTransport._setPlaying(this, false);
    _setSnap(position.inMicroseconds, 0);
    _changes.add(null);
    await _call('pause');
  }

  @override
  Future<void> seek(Duration position) async {
    // Read as there at once, as just_audio's position is, rather than where
    // the player was until the native seek reports back.
    _completed = false;
    _setSnap(position.inMicroseconds, 0);
    await _seekBy('seek', position);
  }

  @override
  Future<void> seekFresh(Duration position) async {
    _completed = false;
    _setSnap(position.inMicroseconds, 0);
    await _seekBy('seekFresh', position);
  }

  Future<void> _seekBy(String method, Duration position) async {
    _seeksInFlight++;
    try {
      await _call(method, {'ms': position.inMilliseconds});
    } finally {
      _seeksInFlight--;
    }
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await _call('setRate', {'rate': speed});
  }

  @override
  Duration get position {
    var us = _snapUs.toDouble();
    if (_snapRate > 0) us += (_nowUs - _snapWallUs) * _snapRate;
    final endUs = (_endMs ?? _duration.inMilliseconds) * 1000;
    if (endUs > 0 && us > endUs) us = endUs.toDouble();
    return Duration(microseconds: us.round());
  }

  @override
  Duration? get duration => _duration;
  @override
  bool get playing => _playing;
  @override
  bool get completed => _completed;
  @override
  bool get failed => _failed;
  @override
  Stream<void> get changes => _changes.stream;
  @override
  ValueListenable<VideoPicture?> get picture => _picture;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    MediaTransport._setPlaying(this, false);
    await _sub.cancel();
    _picture.value = null;
    await _call('dispose');
    _disposed = true;
    await _changes.close();
  }
}
