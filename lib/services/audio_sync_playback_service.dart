import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:just_audio/just_audio.dart';

import '../models/audio_track_variant.dart';
import '../models/parsed_piece.dart';
import 'audio_score_auto_aligner.dart';
import 'audio_sync_anchors_store.dart';
import 'midi_generator.dart';
import 'playback_service_base.dart';

/// Drives the inherited highlight-tracking machinery from a real audio
/// file's playback position instead of wall-clock+BPM — same base class as
/// the metronome/soundfont `PlaybackService`, just a different clock source
/// ([currentPlaybackSeconds]) and a different "instrument" ([onPlayStarted]/
/// [onStopped]/[onTick] drive a real [AudioPlayer] instead of MIDI notes).
///
/// Calibration is fully automatic (see [AudioScoreAutoAligner]) — no tap-along
/// step. [load] checks [AudioSyncAnchorsStore] for a cached alignment first;
/// if absent, it runs the aligner once (against a bundled WAV asset used only
/// for analysis — playback itself still uses the mp3) and persists the
/// result, so alignment only ever runs once per device per piece/track.
class AudioSyncPlaybackService extends PlaybackServiceBase {
  final AudioSyncAnchorsStore _store;
  final AudioPlayer _player = AudioPlayer();

  List<ScoreAudioAnchor> _anchors = const [];

  /// True while the one-time on-device alignment is running (first load of a
  /// piece/track with no cached anchors yet) — the UI shows a brief
  /// "Aligning…" state instead of playback controls while this is true.
  final ValueNotifier<bool> isAligning = ValueNotifier(false);

  /// True when the current alignment (fresh or cached) shows the
  /// anchor-compression signature — see [AutoAlignmentResult.hasCompressedAnchors].
  /// The UI should surface [alignmentReviewMessage] rather than silently
  /// trusting a possibly-off alignment.
  final ValueNotifier<bool> alignmentLooksUncertain = ValueNotifier(false);

  AudioSyncPlaybackService(super.generator, {AudioSyncAnchorsStore? store})
      : _store = store ?? AudioSyncAnchorsStore();

  List<ScoreAudioAnchor> get anchors => List.unmodifiable(_anchors);

  /// Sorts anchors by [ScoreAudioAnchor.audioSec], breaking ties on
  /// [ScoreAudioAnchor.scoreMs]. Salt Creek's B section is chroma-identical to
  /// A (chroma is octave-invariant), so the DTW cost matrix has little to
  /// discriminate on right at a repeat boundary and two anchors can land on
  /// equal/near-equal audioSec — `List.sort` isn't stable, so an explicit
  /// tie-break keeps [currentPlaybackSeconds]'s interpolation genuinely
  /// monotonic instead of occasionally inverted.
  static List<ScoreAudioAnchor> sortAnchors(List<ScoreAudioAnchor> anchors) {
    return [...anchors]..sort((a, b) {
      final byAudio = a.audioSec.compareTo(b.audioSec);
      return byAudio != 0 ? byAudio : a.scoreMs.compareTo(b.scoreMs);
    });
  }

  /// Loads [track] of [audioFolder] for [piece] (keyed by [pieceId] in the
  /// anchors cache) for playback. Runs the one-time auto-alignment if
  /// nothing is cached yet for this piece — always against the `melody`
  /// track regardless of [track], since that's the closest match to the
  /// score's own notes and so the best-conditioned DTW reference; the
  /// resulting anchors are timeline-shared across all of a piece's track
  /// variants (see [AudioSyncAnchorsStore]).
  Future<void> load({
    required ParsedPiece piece,
    required String pieceId,
    required String audioFolder,
    required AudioTrackVariant track,
  }) async {
    final cached = await _store.load(pieceId);
    final List<ScoreAudioAnchor> anchors;
    final int generationBpm;
    if (cached != null) {
      anchors = cached.anchors;
      generationBpm = cached.generationBpm;
      alignmentLooksUncertain.value = cached.hasCompressedAnchors;
    } else {
      isAligning.value = true;
      try {
        final wavData = await rootBundle
            .load('assets/audio/$audioFolder/${AudioTrackVariant.melody.id}.wav');
        final wavBytes = wavData.buffer
            .asUint8List(wavData.offsetInBytes, wavData.lengthInBytes);
        final result =
            AudioScoreAutoAligner(midiGenerator: generator).align(piece, wavBytes);
        anchors = result.anchors;
        generationBpm = result.generationBpm;
        alignmentLooksUncertain.value = result.hasCompressedAnchors;
        await _store.save(pieceId,
            anchors: anchors,
            generationBpm: generationBpm,
            hasCompressedAnchors: result.hasCompressedAnchors);
      } finally {
        isAligning.value = false;
      }
    }
    assert(anchors.length >= 2, 'Alignment produced fewer than 2 anchors.');
    _anchors = sortAnchors(anchors);
    await loadPieceAtBpm(piece, generationBpm);
    await _player.setAsset(track.assetPathIn(audioFolder));
  }

  /// Clears any cached alignment and re-runs it from scratch.
  Future<void> realign({
    required ParsedPiece piece,
    required String pieceId,
    required String audioFolder,
    required AudioTrackVariant track,
  }) async {
    await _store.clear(pieceId);
    await load(
        piece: piece, pieceId: pieceId, audioFolder: audioFolder, track: track);
  }

  /// Piecewise-linear interpolation across every anchor — unlike a single
  /// global line through just the first/last point, this can represent real
  /// local tempo variation between measures. Positions outside the anchor
  /// range extrapolate along the nearest segment.
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

  /// Index `i` such that segment `[i, i+1]` brackets [audioSec] (clamped to
  /// the nearest end segment when out of range) — `i+1` is always valid.
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

  Future<void> setPlaybackSpeed(double speed) => _player.setSpeed(speed);

  @override
  double? currentPlaybackSeconds() {
    if (_anchors.length < 2) return null;
    return _scoreSecForAudioSec(_player.position.inMicroseconds / 1e6);
  }

  /// Looks ahead by [highlightLeadSeconds] on the real audio clock, THEN
  /// maps that future position through the anchor curve — not the other way
  /// around. [_scoreSecForAudioSec] is piecewise-linear with a different
  /// local slope between each pair of anchors (real recorded tempo isn't the
  /// generated score's tempo, and drifts bar to bar), so padding its output
  /// in score-seconds would give a different amount of real-world
  /// anticipation depending where in the piece playback currently is —
  /// pronounced across a segment with a near-1:1 slope, next to invisible
  /// across a compressed one. Padding the input keeps the lead pinned to
  /// real seconds, which is what a listener actually perceives.
  @override
  double? highlightAdvanceSeconds() {
    if (_anchors.length < 2) return null;
    final aheadAudioSec =
        _player.position.inMicroseconds / 1e6 + highlightLeadSeconds;
    return _scoreSecForAudioSec(aheadAudioSec);
  }

  /// The real-audio position to start playback from for a [play] that began
  /// at [startOffsetSeconds]. Starting from the piece's true beginning
  /// (`startOffsetSeconds == 0`) seeks to the recording's real `0` instead of
  /// [_audioSecForScoreSec]'s answer (the first anchor — see
  /// docs/audio-sync-dtw-open-boundaries.md) so any unmatched intro the
  /// recording has still plays; starting mid-piece has no such intro to play
  /// and seeks straight to the mapped position as before.
  double _seekTargetAudioSec(double startOffsetSeconds) =>
      startOffsetSeconds <= 0 ? 0.0 : _audioSecForScoreSec(startOffsetSeconds);

  /// Nothing to highlight yet while real playback is still inside an
  /// unmatched intro (see [_seekTargetAudioSec]) — [_scoreSecForAudioSec]
  /// would otherwise extrapolate backward past the first anchor into a
  /// meaningless negative score position that [PlaybackServiceBase] would
  /// clamp onto note 0, lighting it up well before it actually plays.
  @override
  double? initialHighlightSeconds() {
    if (_anchors.length < 2) return null;
    final audioSec = _seekTargetAudioSec(startOffsetSeconds);
    if (audioSec < _anchors.first.audioSec) return null;
    return _scoreSecForAudioSec(audioSec + highlightLeadSeconds);
  }

  /// Always seeks first — the underlying native player is not recreated by a
  /// Dart-level hot restart, so without an explicit seek it resumes wherever
  /// a previous run left it rather than actually starting over.
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
  }
}
