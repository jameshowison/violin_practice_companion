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

/// Where a recording's count-in comes from when the recording itself doesn't
/// supply enough lead-in before the first note: silence, or the bars before.
enum RecordingLeadInMode { silent, preroll }

/// How a recording's play-through is started so a count-in lands on its entry.
/// All in the RECORDING's seconds except [waitRealSec]. See
/// [MediaPlaybackService.recordingLeadIn].
typedef LeadInPlan = ({
  /// Where the audio is sought to before it plays.
  double seekAudioSec,

  /// How long the audio is held, in wall-clock seconds, before it plays — the
  /// silent part of the count.
  double waitRealSec,

  /// The recording position the count's first beat corresponds to (negative
  /// when it falls before the file starts, i.e. in the silent wait).
  double countStartAudioSec,

  /// The recording position of the first note — the count's landing.
  double entryAudioSec,

  /// Score-seconds per recording-second around the entry: the recording's
  /// local tempo, which is what the count is spaced at.
  double scorePerAudio,
});

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

  /// Where the count-in's lead-in comes from when the recording can't supply
  /// it — set by the transport from the app-wide preference before [play].
  RecordingLeadInMode leadInMode = RecordingLeadInMode.silent;

  // The current play-through's lead-in, while a count-in is being given.
  LeadInPlan? _leadIn;
  Timer? _leadInTimer;
  // Wall-clock second at which a silent lead-in ends and the audio starts.
  double? _leadInEndsAt;
  // True until the start seek has landed: until then the player's position is
  // wherever the previous run left it.
  bool _seekPending = false;
  // Bumped per play so a stale seek/timer can't start a later run's audio.
  int _playGeneration = 0;
  // The virtual position never runs backward across the hand-over from the
  // wall clock to the player's (which reports late for a moment on start).
  double _lastVirtualAudioSec = double.negativeInfinity;

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

  /// The loaded recording's own tempo in quarter-note bpm, measured from its
  /// alignment; null when it isn't aligned. See [recordingBpmFrom].
  double? get recordingBpm => recordingBpmFrom(_anchors, _generationBpm);
  int _generationBpm = 0;

  /// A recording's tempo, from its anchors: the score time they span (at
  /// [generationBpm], which every `scoreMs` was generated at) over the audio
  /// time they span. First to last anchor only, so a lead-in or a trailing
  /// piano outro doesn't count — which is what makes this better than
  /// [generationBpm] itself, an estimate from the file's whole duration.
  static double? recordingBpmFrom(
      List<ScoreAudioAnchor> anchors, int generationBpm) {
    if (anchors.length < 2 || generationBpm <= 0) return null;
    final scoreSec = (anchors.last.scoreMs - anchors.first.scoreMs) / 1000;
    final audioSec = anchors.last.audioSec - anchors.first.audioSec;
    if (scoreSec <= 0 || audioSec <= 0) return null;
    return generationBpm * scoreSec / audioSec;
  }

  /// Slowest and fastest a recording is played: past these the time-stretch
  /// is audibly smeared, and a preset that far from the recording is better
  /// served by the synthesized score.
  static const minSpeed = 0.5, maxSpeed = 2.0;

  /// The playback rate that plays a recording at [recordingBpm] at
  /// [targetBpm] — how the tray's shared Slow / Medium / Performance presets
  /// apply to a recording. 1.0 when the recording's tempo is unknown.
  static double speedFor(double targetBpm, double? recordingBpm) {
    if (recordingBpm == null || recordingBpm <= 0) return 1.0;
    return (targetBpm / recordingBpm).clamp(minSpeed, maxSpeed);
  }

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
    _generationBpm = alignment?.generationBpm ?? 0;

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

  /// How to start a recording so a count of [countScoreSec] (score-seconds,
  /// at the alignment's generation tempo — the same seconds the anchors'
  /// `scoreMs` are in) lands on the note at [startScoreSec].
  ///
  /// The count is extended BACK from the known entry at the recording's local
  /// tempo, so it lines up with the recording's own pulse, intro or not:
  /// - from the beginning ([fromBeginning]) the file plays from 0 as it always
  ///   has, and an intro at least as long as the count simply carries it — no
  ///   wait at all. A shorter intro is topped up with silence first.
  /// - mid-piece, [preroll] starts the audio a count early, so the bars before
  ///   the entry play under it (silence for whatever falls before the file's
  ///   start); otherwise the audio waits at the entry for the whole count.
  ///
  /// Null when there aren't two anchors to place anything with.
  static LeadInPlan? recordingLeadIn({
    required List<ScoreAudioAnchor> anchors,
    required double startScoreSec,
    required double countScoreSec,
    required bool fromBeginning,
    required bool preroll,
    double speed = 1.0,
  }) {
    if (anchors.length < 2 || countScoreSec <= 0) return null;
    final entry = audioSecForScoreSec(anchors, startScoreSec);
    final slope = localScorePerAudio(anchors, startScoreSec,
        windowScoreSec: countScoreSec * 2);
    final countAudio = countScoreSec / slope;
    final countStart = entry - countAudio;
    final double seek;
    if (fromBeginning) {
      seek = 0;
    } else if (preroll) {
      seek = countStart < 0 ? 0 : countStart;
    } else {
      seek = entry;
    }
    final behind = seek - countStart;
    return (
      seekAudioSec: seek,
      waitRealSec: behind <= 0 ? 0 : behind / (speed <= 0 ? 1 : speed),
      countStartAudioSec: countStart,
      entryAudioSec: entry,
      scorePerAudio: slope,
    );
  }

  /// Score-seconds per recording-second just after [startScoreSec]: from the
  /// anchor at (or the last before) the start to the last within
  /// [windowScoreSec] past it. Forward only — what comes before the entry may
  /// be an intro the anchors don't describe. Falls back to the whole
  /// alignment's slope, and to 1, if that window is degenerate.
  static double localScorePerAudio(
      List<ScoreAudioAnchor> anchors, double startScoreSec,
      {required double windowScoreSec}) {
    double slopeOf(ScoreAudioAnchor a, ScoreAudioAnchor b) =>
        (b.scoreMs - a.scoreMs) / 1000 / (b.audioSec - a.audioSec);
    bool ok(double v) => v.isFinite && v > 0;

    final startMs = startScoreSec * 1000;
    final endMs = startMs + windowScoreSec * 1000;
    var i = 0;
    while (i + 2 < anchors.length && anchors[i + 1].scoreMs <= startMs) {
      i++;
    }
    var j = i + 1;
    while (j + 1 < anchors.length && anchors[j + 1].scoreMs <= endMs) {
      j++;
    }
    final local = slopeOf(anchors[i], anchors[j]);
    if (ok(local)) return local;
    final global = slopeOf(anchors.first, anchors.last);
    return ok(global) ? global : 1.0;
  }

  /// [anchors]' inverse map, score-seconds → recording-seconds, extrapolating
  /// along the end segments.
  static double audioSecForScoreSec(
      List<ScoreAudioAnchor> anchors, double scoreSec) {
    final scoreMs = scoreSec * 1000;
    final lo = _bracketBelowByScoreMs(anchors, scoreMs);
    final a = anchors[lo], b = anchors[lo + 1];
    final t = (scoreMs - a.scoreMs) / (b.scoreMs - a.scoreMs);
    return a.audioSec + t * (b.audioSec - a.audioSec);
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

  double _audioSecForScoreSec(double scoreSec) =>
      audioSecForScoreSec(_anchors, scoreSec);

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

  static int _bracketBelowByScoreMs(
      List<ScoreAudioAnchor> anchors, double scoreMs) {
    if (scoreMs <= anchors.first.scoreMs) return 0;
    if (scoreMs >= anchors[anchors.length - 2].scoreMs) {
      return anchors.length - 2;
    }
    var lo = 0, hi = anchors.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (anchors[mid].scoreMs <= scoreMs) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  @override
  bool get supportsCountIn => isAligned;

  static double _wallNow() => DateTime.now().microsecondsSinceEpoch / 1e6;

  /// The recording position playback is at, counting a silent lead-in as the
  /// stretch of "recording" before [LeadInPlan.seekAudioSec] — so the count
  /// runs on one clock whether it is heard over the intro, over silence, or
  /// over both in turn.
  double _virtualAudioSec(LeadInPlan lead) {
    final double v;
    final endsAt = _leadInEndsAt;
    final now = _wallNow();
    if (endsAt != null && now < endsAt) {
      v = lead.seekAudioSec - (endsAt - now) * playbackSpeed.value;
    } else if (_seekPending) {
      v = lead.seekAudioSec;
    } else {
      v = _player.position.inMicroseconds / 1e6;
    }
    if (v > _lastVirtualAudioSec) _lastVirtualAudioSec = v;
    return _lastVirtualAudioSec;
  }

  /// Before the entry, during a count-in, score time is a straight line back
  /// from the entry at the local tempo — so the count's last beat falls on the
  /// first note however the anchor curve's first segment happens to lie.
  /// After it, and with no count, the anchor curve as always.
  @override
  double? currentPlaybackSeconds() {
    if (!isAligned) return null;
    final lead = _leadIn;
    if (lead != null) {
      final v = _virtualAudioSec(lead);
      if (v < lead.entryAudioSec) {
        return countInLandingSeconds -
            (lead.entryAudioSec - v) * lead.scorePerAudio;
      }
    }
    return _scoreSecForAudioSec(_player.position.inMicroseconds / 1e6);
  }

  @override
  void prepareStart(double startOffsetSeconds) {
    _leadInTimer?.cancel();
    _leadInTimer = null;
    _leadInEndsAt = null;
    _lastVirtualAudioSec = double.negativeInfinity;
    _leadIn = activeCountIn == null
        ? null
        // Counted back from the first note HEARD — the one the alignment
        // actually knows — so a pickup's hidden lead rest is part of the count.
        : recordingLeadIn(
            anchors: _anchors,
            startScoreSec: countInLandingSeconds,
            countScoreSec:
                countInSeconds + countInLandingSeconds - startOffsetSeconds,
            fromBeginning: startOffsetSeconds <= 0,
            preroll: leadInMode == RecordingLeadInMode.preroll,
            speed: playbackSpeed.value,
          );
  }

  @override
  double get scoreSecondsPerRealSecond {
    final lead = _leadIn;
    return lead == null ? 1.0 : lead.scorePerAudio * playbackSpeed.value;
  }

  /// The intro's start in score-seconds, when the file starts playing before
  /// the count does (a from-the-top start into a recording with an intro).
  @override
  double? get introStartSeconds {
    final lead = _leadIn;
    if (lead == null || lead.seekAudioSec >= lead.countStartAudioSec) {
      return null;
    }
    return countInLandingSeconds -
        (lead.entryAudioSec - lead.seekAudioSec) * lead.scorePerAudio;
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
    // Counting in with nothing of the recording before the count: sit on the
    // note being counted towards, as the synthesized score does.
    final lead = _leadIn;
    if (lead != null) {
      return introStartSeconds == null
          ? startOffsetSeconds + highlightLeadSeconds
          : null;
    }
    final audioSec = _seekTargetAudioSec(startOffsetSeconds);
    if (audioSec < _anchors.first.audioSec) return null;
    return _scoreSecForAudioSec(audioSec + highlightLeadSeconds);
  }

  /// Always seeks first — the underlying native player is not recreated by a
  /// Dart-level hot restart, so without an explicit seek it resumes wherever
  /// a previous run left it rather than actually starting over.
  ///
  /// With a count-in, the seek and any silent wait come from the play-through's
  /// [LeadInPlan] (see [prepareStart]), and the audio starts only once the
  /// seek has landed — so the virtual clock never reads a stale position.
  @override
  void onPlayStarted(MidiData data, double startOffsetSeconds) {
    final generation = ++_playGeneration;
    final lead = _leadIn;
    if (lead == null) {
      final audioSec = _seekTargetAudioSec(startOffsetSeconds);
      _player.seek(Duration(microseconds: (audioSec * 1e6).round()));
      unawaited(_player.play());
      return;
    }
    if (lead.waitRealSec > 0) {
      _leadInEndsAt = _wallNow() + lead.waitRealSec;
    }
    _seekPending = true;
    final seek = _player
        .seek(Duration(microseconds: (lead.seekAudioSec * 1e6).round()))
        .whenComplete(() {
      if (generation == _playGeneration) _seekPending = false;
    });
    void start() {
      if (generation != _playGeneration ||
          playbackState != PlaybackState.playing) {
        return;
      }
      unawaited(_player.play());
    }

    if (lead.waitRealSec > 0) {
      _leadInTimer = Timer(
          Duration(microseconds: (lead.waitRealSec * 1e6).round()), () async {
        await seek;
        start();
      });
    } else {
      unawaited(seek.then((_) => start()));
    }
  }

  @override
  void onStopped() {
    _playGeneration++;
    _leadInTimer?.cancel();
    _leadInTimer = null;
    _leadInEndsAt = null;
    _seekPending = false;
    _player.pause();
  }

  @override
  void onTick(double playbackTime, MidiData data) {
    // No-op: the recording already makes the sound; nothing to trigger.
  }

  @override
  void dispose() {
    _leadInTimer?.cancel();
    super.dispose();
    unawaited(_playerStateSub?.cancel());
    _player.dispose();
    isAligning.dispose();
    alignmentLooksUncertain.dispose();
    playbackSpeed.dispose();
  }
}
