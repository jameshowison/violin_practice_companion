import 'package:musicxml_tools/musicxml_tools.dart';

import 'package:score_sync/score_sync.dart';
import 'audio_decoder_base.dart' show PcmAudio;
import 'midi_generator.dart';

/// [ScoreAligner] for the app's own scores: a [ParsedPiece], laid out in
/// time by [MidiGenerator].
///
/// The aligner's static passes ([ScoreAligner.heldBarlines] and the rest) are
/// on [ScoreAligner]; Dart doesn't inherit statics.
class AudioScoreAutoAligner extends ScoreAligner<ParsedPiece> {
  AudioScoreAutoAligner({
    MidiGenerator? midiGenerator,
    AudioChromaExtractor? extractor,
    DtwAligner? dtw,
  }) : super(
          timing: _timingOf(midiGenerator ?? MidiGenerator()),
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
