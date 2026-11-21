import 'package:meta/meta.dart';

import 'audio_chroma_features.dart';
import 'dtw_align.dart';
import 'score_chroma_reference.dart';

/// The alignment parameters that depend on the instrument being played,
/// gathered in one value that [ScoreAligner] takes as `profile`.
///
/// - [minFrequencyHz] and [maxFrequencyHz]: the band the chroma is read from
///   ([AudioChromaExtractor]). Its floor should sit below the instrument's
///   lowest note, with a margin, or that note's fundamental is not heard.
/// - [ringSeconds]: how long a note rings on into a following rest in the
///   score's reference ([ScoreChromaReferenceBuilder.ringSeconds]): about a
///   second for a string, near zero for an instrument that stops dead.
/// - [onsetWeight]: how much a note start in the recording counts against
///   one in the score ([DtwAligner.onsetWeight]).
///
/// Everything else in the aligner is about recordings, not instruments, and
/// stays on the parts themselves.
///
/// The defaults are [bowedStrings]: what the aligner was tuned on, a violin.
/// Other families want other values (`docs/family/approach.md`, Part 2).
///
/// Plain doubles, so a profile can be sent to another isolate.
@immutable
class AlignmentProfile {
  /// The bottom of the chroma band, in Hz.
  final double minFrequencyHz;

  /// The top of the chroma band, in Hz.
  final double maxFrequencyHz;

  /// Seconds a note rings on into a following rest in the reference.
  final double ringSeconds;

  /// Weight of the onset term in the DTW's cost (0 aligns on pitch alone).
  final double onsetWeight;

  const AlignmentProfile({
    this.minFrequencyHz = 180,
    this.maxFrequencyHz = 2600,
    this.ringSeconds = 1.0,
    this.onsetWeight = 0.3,
  });

  /// The aligner's own values, tuned on violin: a 180-2600 Hz band, a second
  /// of ring, onset weight 0.3. Identical to the parts' defaults.
  static const bowedStrings = AlignmentProfile();

  /// An extractor reading this profile's band, otherwise the default one.
  AudioChromaExtractor extractor() => AudioChromaExtractor(
      minFrequencyHz: minFrequencyHz, maxFrequencyHz: maxFrequencyHz);

  /// A reference builder ringing notes for [ringSeconds].
  ScoreChromaReferenceBuilder referenceBuilder() =>
      ScoreChromaReferenceBuilder(ringSeconds: ringSeconds);

  /// A DTW with this profile's [onsetWeight], otherwise the default one.
  DtwAligner dtw() => DtwAligner(onsetWeight: onsetWeight);

  AlignmentProfile copyWith({
    double? minFrequencyHz,
    double? maxFrequencyHz,
    double? ringSeconds,
    double? onsetWeight,
  }) =>
      AlignmentProfile(
        minFrequencyHz: minFrequencyHz ?? this.minFrequencyHz,
        maxFrequencyHz: maxFrequencyHz ?? this.maxFrequencyHz,
        ringSeconds: ringSeconds ?? this.ringSeconds,
        onsetWeight: onsetWeight ?? this.onsetWeight,
      );

  @override
  bool operator ==(Object other) =>
      other is AlignmentProfile &&
      other.minFrequencyHz == minFrequencyHz &&
      other.maxFrequencyHz == maxFrequencyHz &&
      other.ringSeconds == ringSeconds &&
      other.onsetWeight == onsetWeight;

  @override
  int get hashCode =>
      Object.hash(minFrequencyHz, maxFrequencyHz, ringSeconds, onsetWeight);

  @override
  String toString() => 'AlignmentProfile($minFrequencyHz-$maxFrequencyHz Hz, '
      'ring ${ringSeconds}s, onset $onsetWeight)';
}
