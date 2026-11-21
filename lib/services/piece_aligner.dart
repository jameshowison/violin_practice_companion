import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:musicxml_tools/musicxml_tools.dart';
import 'package:score_sync/score_sync.dart';

import 'package:audio_decoder/audio_decoder.dart' show PcmAudio;
import 'midi_generator.dart';

/// [ScoreAligner] for the app's own scores: a [ParsedPiece], laid out in
/// time by [MidiGenerator].
///
/// The aligner's static passes ([ScoreAligner.heldBarlines] and the rest) are
/// on [ScoreAligner]; Dart doesn't inherit statics.
class AudioScoreAutoAligner extends ScoreAligner<ParsedPiece> {
  final MidiGenerator _generator;

  /// Whether this aligner can be rebuilt in another isolate as it is: only
  /// the generator travels, so a custom extractor or DTW (a test's) can't.
  final bool _defaultParts;

  AudioScoreAutoAligner({
    MidiGenerator? midiGenerator,
    AudioChromaExtractor? extractor,
    DtwAligner? dtw,
  }) : this._with(
            midiGenerator ?? MidiGenerator(), extractor, dtw,
            extractor == null && dtw == null);

  AudioScoreAutoAligner._with(this._generator, AudioChromaExtractor? extractor,
      DtwAligner? dtw, this._defaultParts)
      : super(
          timing: _timingOf(_generator),
          extractor: extractor,
          dtw: dtw,
        );

  static ScoreTiming<ParsedPiece> _timingOf(MidiGenerator generator) =>
      (piece, bpm) => generator.generate(piece, bpm);

  /// [ScoreAligner.alignSamples] on audio an `AudioDecoder` has read.
  AutoAlignmentResult alignPcm(
    ParsedPiece piece,
    PcmAudio audio, {
    double? contentStartSeconds,
    double? contentEndSeconds,
  }) =>
      alignSamples(
        piece,
        audio.samples,
        audio.sampleRate,
        contentStartSeconds: contentStartSeconds,
        contentEndSeconds: contentEndSeconds,
      );

  /// [align] (WAV bytes) or [alignPcm] off the UI isolate, so a long
  /// recording doesn't freeze the screen while it aligns: the DTW is seconds
  /// of CPU on a phone. Give exactly one of [wavBytes] and [pcm]. The result
  /// is the same as on this isolate; the piece and the audio are copied over.
  Future<AutoAlignmentResult> alignInBackground(
    ParsedPiece piece, {
    Uint8List? wavBytes,
    PcmAudio? pcm,
    double? contentStartSeconds,
    double? contentEndSeconds,
  }) {
    assert((wavBytes == null) != (pcm == null), 'Give wavBytes or pcm');
    assert(_defaultParts, 'Only the generator is rebuilt in the isolate');
    return compute(_alignJob, (
      generator: _generator,
      piece: piece,
      wavBytes: wavBytes,
      pcm: pcm,
      start: contentStartSeconds,
      end: contentEndSeconds,
    ));
  }

  // Static, so the isolate's closure carries only the job, not this object.
  static AutoAlignmentResult _alignJob(
      ({
        MidiGenerator generator,
        ParsedPiece piece,
        Uint8List? wavBytes,
        PcmAudio? pcm,
        double? start,
        double? end,
      }) job) {
    final aligner = AudioScoreAutoAligner(midiGenerator: job.generator);
    final wav = job.wavBytes;
    return wav != null
        ? aligner.align(job.piece, wav,
            contentStartSeconds: job.start, contentEndSeconds: job.end)
        : aligner.alignPcm(job.piece, job.pcm!,
            contentStartSeconds: job.start, contentEndSeconds: job.end);
  }
}

/// Suggested message for the UI to show when [AutoAlignmentResult.hasCompressedAnchors]
/// (or a cached alignment's stored equivalent) is true.
///
/// Deliberately names both causes and does not assert which. The wording used
/// to blame the score outright, on the strength of the one confirmed case
/// (Salt Creek's duplicate measures — see
/// docs/audio-sync-dtw-anchor-compression.md). That is no longer safe: with
/// that score corrected, the same recording still trips the flag while every
/// one of its 32 anchors lands within 100ms of a real note onset, so the
/// signal now has a known false-positive mode and shouldn't send anyone
/// hunting for a score bug that isn't there.
const String alignmentReviewMessage =
    'Some measures may be highlighted slightly early or late. If the score '
    "doesn't quite match what was played, check for an extra or missing "
    'measure, or a first/second ending that isn\'t marked (mark it in the '
    'measure editor), then tap Realign. Otherwise the '
    'recording itself may be hard to follow — a quiet one, or one with a lot '
    'of background hum, gives the aligner less to work with. Playback is '
    'usable either way.';
