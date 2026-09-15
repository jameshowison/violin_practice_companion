import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/parsed_piece.dart';
import 'audio_score_auto_aligner.dart';
import 'audio_sync_playback_service.dart' show AudioSyncPlaybackService;
import 'midi_generator.dart';
import 'playback_service_base.dart';
import 'teacher_recording_store.dart';

/// Drives the score highlight from a user-recorded "teacher demo" instead of
/// a bundled Play Along track — structurally the same idea as
/// [AudioSyncPlaybackService] (piecewise-linear anchor interpolation over a
/// real audio player's clock, open-begin/open-end DTW already baked into the
/// anchors it loads), but sourcing its WAV from a file on disk via
/// [TeacherRecordingStore] rather than a bundled asset, and kept as its own
/// class rather than sharing [AudioSyncPlaybackService] so neither feature
/// risks the other.
///
/// Also exposes [rawAudioPosition]/[avOffsetMs]/[playbackSpeed] and
/// [videoPath] for the floating video overlay to mirror — that widget is not
/// on the score's highlight timeline, it needs the *real* recording clock.
class TeacherRecordingPlaybackService extends PlaybackServiceBase {
  final TeacherRecordingStore _store;
  final AudioPlayer _player = AudioPlayer();

  List<ScoreAudioAnchor> _anchors = const [];
  String? _videoPath;
  int _avOffsetMs = 0;

  /// True while the DTW alignment is (re-)running — see [realign]. Loading
  /// an already-aligned recording never sets this; alignment only ever runs
  /// once per recording, right after capture (see RecordTeacherDemoScreen),
  /// unless the user explicitly asks to re-run it.
  final ValueNotifier<bool> isAligning = ValueNotifier(false);

  /// Mirrors [AutoAlignmentResult.hasCompressedAnchors] — see
  /// audio_score_auto_aligner.dart's `alignmentReviewMessage`.
  final ValueNotifier<bool> alignmentLooksUncertain = ValueNotifier(false);

  /// Current playback rate, mirrored here (rather than only living in the
  /// controls tray's local state) so the floating video overlay — a
  /// different widget entirely — can keep its own controller's rate in sync
  /// without a second source of truth.
  final ValueNotifier<double> playbackSpeed = ValueNotifier(1.0);

  TeacherRecordingPlaybackService(super.generator,
      {TeacherRecordingStore? store})
      : _store = store ?? TeacherRecordingStore();

  String? get videoPath => _videoPath;
  int get avOffsetMs => _avOffsetMs;
  Duration get rawAudioPosition => _player.position;

  /// Loads [pieceId]'s already-persisted teacher recording. Returns false if
  /// none exists yet — recording+aligning happens once, up front, in
  /// RecordTeacherDemoScreen, not lazily here (unlike
  /// [AudioSyncPlaybackService.load], there's no bundled asset to fall back
  /// to analyzing on first use).
  Future<bool> load({
    required ParsedPiece piece,
    required String pieceId,
  }) async {
    final cached = await _store.load(pieceId);
    if (cached == null) return false;
    _anchors = AudioSyncPlaybackService.sortAnchors(cached.anchors);
    _videoPath = cached.videoPath;
    _avOffsetMs = cached.avOffsetMs;
    alignmentLooksUncertain.value = cached.hasCompressedAnchors;
    assert(_anchors.length >= 2, 'Alignment produced fewer than 2 anchors.');
    await loadPieceAtBpm(piece, cached.generationBpm);
    await _player.setFilePath(cached.audioPath);
    return true;
  }

  /// Re-runs DTW against the already-recorded audio (e.g. after the score's
  /// measures changed) without re-recording, then reloads.
  Future<void> realign({
    required ParsedPiece piece,
    required String pieceId,
  }) async {
    final cached = await _store.load(pieceId);
    if (cached == null) return;
    isAligning.value = true;
    try {
      final wavBytes = await File(cached.audioPath).readAsBytes();
      final result =
          AudioScoreAutoAligner(midiGenerator: generator).align(piece, wavBytes);
      await _store.save(
        pieceId,
        videoPath: cached.videoPath,
        audioPath: cached.audioPath,
        avOffsetMs: cached.avOffsetMs,
        anchors: result.anchors,
        generationBpm: result.generationBpm,
        hasCompressedAnchors: result.hasCompressedAnchors,
      );
    } finally {
      isAligning.value = false;
    }
    await load(piece: piece, pieceId: pieceId);
  }

  Future<void> setPlaybackSpeed(double speed) async {
    playbackSpeed.value = speed;
    await _player.setSpeed(speed);
  }

  // --- Anchor interpolation — identical shape to AudioSyncPlaybackService;
  // see that class's doc comments for the reasoning behind each piece. Kept
  // separate rather than shared: different store, different file source,
  // and this way neither playback path can break the other. ---

  double _scoreSecForAudioSec(double audioSec) {
    final lo = _bracketBelow(audioSec);
    final a = _anchors[lo], b = _anchors[lo + 1];
    final t = (audioSec - a.audioSec) / (b.audioSec - a.audioSec);
    return (a.scoreMs + t * (b.scoreMs - a.scoreMs)) / 1000.0;
  }

  double _audioSecForScoreSec(double scoreSec) {
    final scoreMs = scoreSec * 1000;
    final lo = _bracketBelowByScoreMs(scoreMs);
    final a = _anchors[lo], b = _anchors[lo + 1];
    final t = (scoreMs - a.scoreMs) / (b.scoreMs - a.scoreMs);
    return a.audioSec + t * (b.audioSec - a.audioSec);
  }

  int _bracketBelow(double audioSec) {
    if (audioSec <= _anchors.first.audioSec) return 0;
    if (audioSec >= _anchors[_anchors.length - 2].audioSec) {
      return _anchors.length - 2;
    }
    var lo = 0, hi = _anchors.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_anchors[mid].audioSec <= audioSec) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  int _bracketBelowByScoreMs(double scoreMs) {
    if (scoreMs <= _anchors.first.scoreMs) return 0;
    if (scoreMs >= _anchors[_anchors.length - 2].scoreMs) {
      return _anchors.length - 2;
    }
    var lo = 0, hi = _anchors.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_anchors[mid].scoreMs <= scoreMs) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  @override
  double? currentPlaybackSeconds() {
    if (_anchors.length < 2) return null;
    return _scoreSecForAudioSec(_player.position.inMicroseconds / 1e6);
  }

  @override
  double? highlightAdvanceSeconds() {
    if (_anchors.length < 2) return null;
    final aheadAudioSec =
        _player.position.inMicroseconds / 1e6 + highlightLeadSeconds;
    return _scoreSecForAudioSec(aheadAudioSec);
  }

  double _seekTargetAudioSec(double startOffsetSeconds) =>
      startOffsetSeconds <= 0 ? 0.0 : _audioSecForScoreSec(startOffsetSeconds);

  @override
  double? initialHighlightSeconds() {
    if (_anchors.length < 2) return null;
    final audioSec = _seekTargetAudioSec(startOffsetSeconds);
    if (audioSec < _anchors.first.audioSec) return null;
    return _scoreSecForAudioSec(audioSec + highlightLeadSeconds);
  }

  @override
  void onPlayStarted(MidiData data, double startOffsetSeconds) {
    final audioSec = _seekTargetAudioSec(startOffsetSeconds);
    _player.seek(Duration(microseconds: (audioSec * 1e6).round()));
    unawaited(_player.play());
  }

  @override
  void onStopped() => _player.pause();

  @override
  void onTick(double playbackTime, MidiData data) {
    // No-op: the real recording already makes the sound; nothing to trigger.
  }

  @override
  void dispose() {
    super.dispose();
    _player.dispose();
    isAligning.dispose();
    alignmentLooksUncertain.dispose();
    playbackSpeed.dispose();
  }
}
