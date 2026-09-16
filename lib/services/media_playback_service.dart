import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/parsed_piece.dart';
import '../models/piece_media.dart';
import 'audio_decoder.dart';
import 'audio_score_auto_aligner.dart';
import 'media_alignment_store.dart';
import 'media_paths.dart';
import 'midi_generator.dart';
import 'playback_service_base.dart';

/// What [MediaPlaybackService.load] made of a medium.
enum MediaLoadOutcome {
  /// Playing, and driving the score highlight from its own clock.
  ready,

  /// Playing, but with no alignment — the decoder could not read it, or it has
  /// no audio track at all. The score does not follow.
  playsWithoutHighlight,

  /// The file this medium names is not on disk. Recoverable by re-importing or
  /// re-recording; nothing here can fix it.
  missing,

  /// The medium is structurally unplayable (no audio ref), or the player
  /// rejected it.
  failed,
}

class MediaLoadResult {
  final MediaLoadOutcome outcome;

  /// Non-null when something went wrong and the tray should say so.
  final String? message;

  const MediaLoadResult(this.outcome, [this.message]);

  bool get isPlayable =>
      outcome == MediaLoadOutcome.ready ||
      outcome == MediaLoadOutcome.playsWithoutHighlight;
}

/// Plays any [PieceMedia] that has a file behind it — a bundled backing track,
/// an imported file, or a recorded demo — and drives the score highlight from
/// its real playback position through the medium's cached DTW alignment.
///
/// This is the merge of `AudioSyncPlaybackService` and
/// `TeacherRecordingPlaybackService`. Those two classes were the same class:
/// the anchor sort, the degenerate-segment filter, both interpolators, both
/// bracket searches, the seek-target rule and all four `PlaybackServiceBase`
/// overrides were character-for-character identical, and the second one's
/// header said as much — *"kept as its own class rather than sharing
/// [AudioSyncPlaybackService] so neither feature risks the other"*. That was a
/// reasonable thing to do while teacher demos were new and might have needed
/// to diverge. They never did, and the cost of the split turned out to be real:
/// a fix to one interpolator is a fix that has to be remembered twice, and the
/// two stores drifted into holding the same anchors under different keys with
/// different migration behaviour.
///
/// What is NOT here is the synthesized score. That is played by the soundfont
/// engine in `PlaybackService`, which triggers real MIDI notes and has no
/// audio file, no anchors and nothing to align. It appears alongside these
/// media in the picker — see [PieceMedia.synthesized] — but merging its engine
/// into this one would mean a class that is two unrelated things joined by an
/// `if`, which is what this file exists to undo.
class MediaPlaybackService extends PlaybackServiceBase {
  final MediaAlignmentStore _store;
  final AudioDecoderBase _decoder;
  final AudioPlayer _player = AudioPlayer();

  List<ScoreAudioAnchor> _anchors = const [];
  PieceMedia? _media;
  String? _videoPath;
  int _avOffsetMs = 0;
  StreamSubscription<PlayerState>? _playerStateSub;

  /// True while a one-time alignment is running — the first load of a medium
  /// with nothing cached, or an explicit [realign]. The tray shows "Aligning…"
  /// rather than controls while this is set.
  final ValueNotifier<bool> isAligning = ValueNotifier(false);

  /// Mirrors [AutoAlignmentResult.hasCompressedAnchors]; the UI surfaces
  /// [alignmentReviewMessage] rather than silently trusting the alignment.
  final ValueNotifier<bool> alignmentLooksUncertain = ValueNotifier(false);

  /// Current playback rate, mirrored here rather than living only in the
  /// tray's local state, so the floating video overlay — a different widget
  /// entirely — can match it without a second source of truth.
  final ValueNotifier<double> playbackSpeed = ValueNotifier(1.0);

  MediaPlaybackService(
    super.generator, {
    MediaAlignmentStore? store,
    AudioDecoderBase? decoder,
  })  : _store = store ?? MediaAlignmentStore(),
        _decoder = decoder ?? const AudioDecoder();

  PieceMedia? get media => _media;
  List<ScoreAudioAnchor> get anchors => List.unmodifiable(_anchors);

  /// Absolute path of this medium's video, already resolved — null when the
  /// medium is audio-only. Read by the floating video overlay.
  String? get videoPath => _videoPath;
  int get avOffsetMs => _avOffsetMs;
  Duration get rawAudioPosition => _player.position;

  /// Whether the score highlight is being driven. False for a medium that
  /// plays but could not be aligned.
  bool get isAligned => _anchors.length >= 2;

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

  /// Drops anchors that would leave a zero-width segment, so every
  /// consecutive pair is strictly increasing in *both* components and the
  /// interpolators below can divide by their deltas unguarded.
  ///
  /// [sortAnchors] only fixes the *ordering* of the equal-`audioSec` anchors
  /// it describes; the pair is still there afterwards, and both
  /// [_scoreSecForAudioSec] and [_audioSecForScoreSec] divide by a segment's
  /// delta with no zero check — a tie made `t` infinite or NaN and threw the
  /// cursor to the end of the piece (or nowhere at all) for as long as that
  /// segment was the bracketed one. Real alignments do produce ties: Salt
  /// Creek's cached anchors have one and the Galopede teacher demo had three.
  ///
  /// Within a run of anchors sharing an `audioSec`, the *last* one survives —
  /// [sortAnchors] has already put the largest `scoreMs` last, and that
  /// instant is the earliest the audio can be said to have reached all of
  /// them. Keeping the earliest instead would stall the cursor at the start
  /// of the run until the next anchor.
  static List<ScoreAudioAnchor> dropDegenerateSegments(
      List<ScoreAudioAnchor> sorted) {
    if (sorted.length < 2) return sorted;
    final kept = <ScoreAudioAnchor>[];
    for (var i = 0; i < sorted.length; i++) {
      final isLastOfAudioRun =
          i == sorted.length - 1 || sorted[i + 1].audioSec != sorted[i].audioSec;
      if (!isLastOfAudioRun) continue;
      // A zero `scoreMs` delta breaks the inverse map the same way a zero
      // `audioSec` delta breaks the forward one.
      if (kept.isNotEmpty && sorted[i].scoreMs == kept.last.scoreMs) continue;
      kept.add(sorted[i]);
    }
    // Never hand back something the `>= 2` checks below can't work with; an
    // unusable pair still interpolates to *something*, where one anchor
    // disables highlight tracking entirely.
    return kept.length >= 2 ? kept : sorted;
  }

  /// Loads [media] for [piece], aligning it first if nothing is cached.
  ///
  /// Alignment runs at most once per [PieceMedia.alignmentKey] — so a piece's
  /// three bundled mixes cost one alignment between them, and switching
  /// between them afterwards is just a different file on the same timeline.
  Future<MediaLoadResult> load({
    required ParsedPiece piece,
    required PieceMedia media,
  }) async {
    final audio = media.audio;
    if (audio == null) {
      return const MediaLoadResult(
          MediaLoadOutcome.failed, 'This medium has no audio.');
    }
    if (!await mediaExists(audio)) {
      return const MediaLoadResult(MediaLoadOutcome.missing,
          'The file for this recording is missing. Re-import or re-record it.');
    }

    _media = media;
    _avOffsetMs = media.avOffsetMs;
    _videoPath = media.video == null ? null : await absolutePathOf(media.video!);

    final alignment = await _alignmentFor(piece, media);
    _anchors = alignment == null
        ? const []
        : dropDegenerateSegments(sortAnchors(alignment.anchors));
    alignmentLooksUncertain.value = alignment?.hasCompressedAnchors ?? false;

    // The generation BPM matters only when there are anchors to be consistent
    // with; unaligned, the timeline is never consulted, and the current tempo
    // is as good a value as any.
    await loadPieceAtBpm(piece, alignment?.generationBpm ?? currentBpm);

    try {
      if (audio.isAsset) {
        await _player.setAsset(audio.path);
      } else {
        await _player.setFilePath((await absolutePathOf(audio))!);
      }
    } catch (e) {
      debugPrint('MediaPlaybackService: player rejected ${media.id} — $e');
      return MediaLoadResult(
          MediaLoadOutcome.failed, "This file can't be played.");
    }

    await _watchForCompletion();
    await setPlaybackSpeed(playbackSpeed.value);

    return isAligned
        ? const MediaLoadResult(MediaLoadOutcome.ready)
        : const MediaLoadResult(
            MediaLoadOutcome.playsWithoutHighlight,
            'This file plays, but it could not be matched to the score, so the '
            'notation will not follow along.',
          );
  }

  /// Cached alignment, or a fresh one, or null when this medium cannot be
  /// aligned at all.
  Future<MediaAlignment?> _alignmentFor(
      ParsedPiece piece, PieceMedia media) async {
    final cached = await _store.load(media.alignmentKey);
    if (cached != null) return cached;

    final analysis = media.analysis;
    if (analysis == null) return null;

    isAligning.value = true;
    try {
      final result = await _runAlignment(piece, media);
      if (result == null) return null;
      final alignment = MediaAlignment(
        anchors: result.anchors,
        generationBpm: result.generationBpm,
        hasCompressedAnchors: result.hasCompressedAnchors,
      );
      // Fewer than two anchors is not a usable alignment and must not be
      // cached — caching it would make every later load skip straight to a
      // result it can't interpolate with.
      if (alignment.anchors.length < 2) return null;
      await _store.save(media.alignmentKey, alignment);
      return alignment;
    } finally {
      isAligning.value = false;
    }
  }

  /// Runs DTW against [media]'s analysis source, decoding it first if it isn't
  /// already WAV, and telling the aligner where in the file the tune is if the
  /// user has said (see [PieceMedia.contentStartSeconds]).
  ///
  /// Returns null on any failure to obtain samples. That is not an error path
  /// so much as the ordinary answer for a file format the platform can't
  /// read — the medium still plays, it just doesn't drive the score.
  Future<AutoAlignmentResult?> _runAlignment(
      ParsedPiece piece, PieceMedia media) async {
    // Non-null by [_alignmentFor]'s own guard, which is where the "this medium
    // can't be aligned at all" answer is produced.
    final analysis = media.analysis!;
    final aligner = AudioScoreAutoAligner(midiGenerator: generator);
    try {
      if (analysis.isWav) {
        return aligner.align(
          piece,
          await readMediaBytes(analysis),
          contentStartSeconds: media.contentStartSeconds,
          contentEndSeconds: media.contentEndSeconds,
        );
      }
      final path = await absolutePathOf(analysis);
      final pcm = path != null
          ? await _decoder.decodeFile(path)
          : await _decoder.decodeBytes(await readMediaBytes(analysis),
              extension: analysis.extension);
      if (pcm == null || pcm.samples.isEmpty) return null;
      return aligner.alignPcm(
        piece,
        pcm,
        contentStartSeconds: media.contentStartSeconds,
        contentEndSeconds: media.contentEndSeconds,
      );
    } catch (e) {
      debugPrint('MediaPlaybackService: alignment failed for $analysis — $e');
      return null;
    }
  }

  /// Clears this medium's cached alignment and runs it again — for when the
  /// score itself has changed since the alignment was computed.
  Future<MediaLoadResult> realign({
    required ParsedPiece piece,
    required PieceMedia media,
  }) async {
    await _store.clear(media.alignmentKey);
    return load(piece: piece, media: media);
  }

  /// Emits a stop when the file runs out.
  ///
  /// Needed because [PlaybackServiceBase] ends playback by comparing SCORE
  /// time against the piece's length, and an unaligned medium has no score
  /// time — [currentPlaybackSeconds] returns null, the tick does nothing, and
  /// without this the transport would sit on "playing" forever after the audio
  /// finished. Harmless for aligned media, which normally reach the score's
  /// end first.
  Future<void> _watchForCompletion() async {
    await _playerStateSub?.cancel();
    _playerStateSub = _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed &&
          playbackState == PlaybackState.playing) {
        stop();
      }
    });
  }

  Future<void> setPlaybackSpeed(double speed) async {
    playbackSpeed.value = speed;
    await _player.setSpeed(speed);
  }

  // --- Anchor interpolation ------------------------------------------------

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

  @override
  double? currentPlaybackSeconds() {
    if (!isAligned) return null;
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
    if (!isAligned) return null;
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
      startOffsetSeconds <= 0 || !isAligned
          ? 0.0
          : _audioSecForScoreSec(startOffsetSeconds);

  /// Nothing to highlight yet while real playback is still inside an
  /// unmatched intro (see [_seekTargetAudioSec]) — [_scoreSecForAudioSec]
  /// would otherwise extrapolate backward past the first anchor into a
  /// meaningless negative score position that [PlaybackServiceBase] would
  /// clamp onto note 0, lighting it up well before it actually plays.
  @override
  double? initialHighlightSeconds() {
    if (!isAligned) return null;
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
    // No-op: the recording already makes the sound; nothing to trigger.
  }

  @override
  void dispose() {
    super.dispose();
    unawaited(_playerStateSub?.cancel());
    _player.dispose();
    isAligning.dispose();
    alignmentLooksUncertain.dispose();
    playbackSpeed.dispose();
  }
}
