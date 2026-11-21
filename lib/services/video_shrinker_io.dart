import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/piece_media.dart';
import 'media_paths.dart';
import 'media_tools.dart';
import 'piece_media_store.dart';

/// Calls the native re-encoder: `shrinkVideo` on the media tools channel
/// (`ios/Runner/MediaToolsPlugin.swift`, `android/.../VideoShrinker.kt`).
/// Returns `{skipped: reason}` or `{width, height, codec, bytes}`; throws
/// [PlatformException] on failure.
typedef NativeVideoShrink = Future<Map<String, Object?>?> Function(
    String source, String destination);

/// Replaces imported videos with a 720p copy, keeping their audio exactly.
///
/// Phone videos arrive at 1080p and 8-12 Mbps — 159 MB for under two minutes
/// in one real case — and the app shows them in a toolbar-height strip or a
/// floating window a few hundred points across. At 720p HEVC, 2 Mbps, that
/// file is 27 MB, and the share bundle that carries it shrinks with it.
///
/// The native side copies the audio track rather than re-encoding it, so the
/// cached alignment stays valid and nothing realigns. Measured on three real
/// videos: decoded audio identical to the original's, at worst offset by 35
/// samples (0.8 ms) where the source's priming trim was not carried over.
///
/// **The swap waits for the next launch.** Shrinking runs in the background
/// as soon as a video is imported, but pointing the medium at the new file
/// mid-session would reload the transport under whoever is playing it
/// (`_MediaTransport.didUpdateWidget` compares media by value), and the
/// session-long media list would then hand the old paths back to the next
/// edit. So a finished shrink is recorded, and [applyFinishedShrinks] makes
/// the swap at launch, before any piece is open. The original is deleted one
/// launch later still, once nothing can be holding its path: a session that
/// read the media list before the swap landed would otherwise find its file
/// gone mid-play.
class VideoShrinker {
  VideoShrinker({
    PieceMediaStore? store,
    NativeVideoShrink? nativeShrink,
    Future<String> Function(String relativePath)? resolve,
  })  : _store = store ?? PieceMediaStore(),
        _native = nativeShrink ?? _channelShrink,
        _resolve = resolve ?? resolveMediaPath;

  static final VideoShrinker instance = VideoShrinker();

  /// The output's shorter side, in pixels. 720 keeps full-screen on an iPad
  /// sharp enough to read a bow hold.
  static const int shortSide = 720;
  static const int bitrate = 2000000;

  /// How long after launch the pass over existing media starts, so it does not
  /// compete with the first engrave for the CPU.
  static const Duration launchPassDelay = Duration(seconds: 20);

  /// Give up on a video after this many failed attempts. A failure can be
  /// transient — iOS refuses the hardware encoder to a backgrounded app — so
  /// one is not enough to stop trying, but a file that fails every time must
  /// not cost an encode on every launch forever.
  static const int maxAttempts = 3;

  /// The replacement's name, next to the original in the medium's folder.
  static const String shrunkFilename = 'video_720.mp4';

  static const String _readyKey = 'videoShrink.ready';
  static const String _retiredKey = 'videoShrink.retired';
  static const String _attemptsKey = 'videoShrink.attempts';
  static const String _mediaPrefix = 'pieceMedia.'; // PieceMediaStore's key prefix

  final PieceMediaStore _store;
  final NativeVideoShrink _native;
  final Future<String> Function(String) _resolve;

  Future<void> _queue = Future.value();

  /// Shrinks [media]'s video in the background, one video at a time. Safe to
  /// call for any medium: one with no video, or an asset-backed one, is a
  /// no-op, and the native side skips a video that is already small.
  void enqueue(String pieceId, PieceMedia media) {
    _queue = _queue.then((_) => shrinkNow(pieceId, media)).catchError((Object e) {
      debugPrint('[video_shrink] ${media.id}: $e');
    });
  }

  /// [enqueue] without the queue: returns once this one video is done.
  @visibleForTesting
  Future<void> shrinkNow(String pieceId, PieceMedia media) async {
    final video = media.video;
    if (video == null || video.isAsset) return;
    final slash = video.path.lastIndexOf('/');
    final folder = slash < 0 ? '' : video.path.substring(0, slash + 1);
    final target = '$folder$shrunkFilename';
    if (target == video.path) return;

    final prefs = await SharedPreferences.getInstance();
    final attemptKey = '$pieceId/${media.id}/${video.path}';
    final attempts = _attempts(prefs);
    if ((attempts[attemptKey] ?? 0) >= maxAttempts) return;

    final source = await _resolve(video.path);
    if (!await File(source).exists()) return;
    final destination = await _resolve(target);

    Future<void> record(int count) async {
      final latest = _attempts(prefs)..[attemptKey] = count;
      await prefs.setString(_attemptsKey, jsonEncode(latest));
    }

    final Map<String, Object?>? outcome;
    try {
      outcome = await _native(source, destination);
    } on MissingPluginException {
      return; // an older native build; nothing to remember
    } on PlatformException catch (e) {
      debugPrint('[video_shrink] ${media.id} failed: ${e.message}');
      await record((attempts[attemptKey] ?? 0) + 1);
      return;
    }
    // Done with this file either way from here on.
    await record(maxAttempts);

    final skipped = outcome?['skipped'];
    if (skipped != null) {
      debugPrint('[video_shrink] ${media.id} left as is: $skipped');
      return;
    }
    final before = await File(source).length();
    final shrunk = File(destination);
    if (!await shrunk.exists() || await shrunk.length() >= before) {
      if (await shrunk.exists()) await shrunk.delete();
      return;
    }
    debugPrint('[video_shrink] ${media.id}: ${_mb(before)} → '
        '${_mb(await shrunk.length())} (${outcome?['width']}x${outcome?['height']} '
        '${outcome?['codec']}); swapped in at next launch');
    final ready = _ready(prefs)
      ..add({'pieceId': pieceId, 'mediaId': media.id, 'from': video.path, 'to': target});
    await prefs.setString(_readyKey, jsonEncode(ready));
  }

  /// Points each medium a finished shrink belongs to at its new file, and
  /// deletes the originals the previous launch's swaps retired. Call at
  /// launch, before any piece's media are read.
  ///
  /// Checks the medium still names the original first: in between, it may
  /// have been deleted, or replaced by a dev-library sync. Then the new file
  /// is the orphan and is the one removed.
  Future<void> applyFinishedShrinks() async {
    final prefs = await SharedPreferences.getInstance();
    await _deleteRetired(prefs);
    final ready = _ready(prefs);
    if (ready.isEmpty) return;
    final retired = prefs.getStringList(_retiredKey) ?? [];
    for (final entry in ready) {
      final pieceId = entry['pieceId'] as String?;
      final mediaId = entry['mediaId'] as String?;
      final from = entry['from'] as String?;
      final to = entry['to'] as String?;
      if (pieceId == null || mediaId == null || from == null || to == null) continue;
      final fromRef = MediaRef.appFile(from);
      final toRef = MediaRef.appFile(to);
      final media =
          (await _store.load(pieceId)).where((m) => m.id == mediaId).firstOrNull;
      final names = media == null
          ? const <MediaRef?>[]
          : [media.audio, media.analysis, media.video];
      final newFile = File(await _resolve(to));
      try {
        if (names.contains(fromRef) && await newFile.exists()) {
          await _store.update(pieceId, media!.withFileReplaced(fromRef, toRef));
          retired.add(from);
          debugPrint('[video_shrink] $mediaId now plays $to');
        } else if (!names.contains(toRef) && await newFile.exists()) {
          await newFile.delete();
        }
      } catch (e) {
        debugPrint('[video_shrink] swap for $mediaId failed: $e');
      }
    }
    await prefs.setStringList(_retiredKey, retired);
    await prefs.remove(_readyKey);
  }

  /// Deletes retired originals that no stored medium names any more. One a
  /// row names again (a dev-library sync can bring the old row back) is kept.
  Future<void> _deleteRetired(SharedPreferences prefs) async {
    final retired = prefs.getStringList(_retiredKey);
    if (retired == null || retired.isEmpty) return;
    final named = <String>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_mediaPrefix)) continue;
      for (final m in await _store.load(key.substring(_mediaPrefix.length))) {
        for (final ref in [m.audio, m.analysis, m.video]) {
          if (ref != null && !ref.isAsset) named.add(ref.path);
        }
      }
    }
    for (final path in retired) {
      if (named.contains(path)) continue;
      try {
        final file = File(await _resolve(path));
        if (await file.exists()) await file.delete();
      } catch (e) {
        debugPrint('[video_shrink] could not delete $path: $e');
      }
    }
    await prefs.remove(_retiredKey);
  }

  /// After [launchPassDelay], queues every stored medium with a video. The
  /// attempt record keeps this to a quick no-op for videos already done.
  void scheduleLaunchPass() {
    Timer(launchPassDelay, () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        for (final key in prefs.getKeys()) {
          if (!key.startsWith(_mediaPrefix)) continue;
          final pieceId = key.substring(_mediaPrefix.length);
          for (final media in await _store.load(pieceId)) {
            if (media.video != null) enqueue(pieceId, media);
          }
        }
      } catch (e) {
        debugPrint('[video_shrink] launch pass failed: $e');
      }
    });
  }

  static List<Map<String, dynamic>> _ready(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_readyKey);
      if (raw == null) return [];
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  static Map<String, int> _attempts(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_attemptsKey);
      if (raw == null) return {};
      return (jsonDecode(raw) as Map).cast<String, int>();
    } catch (_) {
      return {};
    }
  }

  static String _mb(int bytes) => '${(bytes / 1e6).toStringAsFixed(1)} MB';

  static Future<Map<String, Object?>?> _channelShrink(
          String source, String destination) =>
      MediaTools.channel.invokeMapMethod<String, Object?>('shrinkVideo', {
        'source': source,
        'destination': destination,
        'shortSide': shortSide,
        'bitrate': bitrate,
      });
}
