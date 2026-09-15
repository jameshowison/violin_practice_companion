import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'audio_score_auto_aligner.dart';

/// One medium's cached score-to-audio alignment.
class MediaAlignment {
  /// One anchor per performed measure, in performance order.
  final List<ScoreAudioAnchor> anchors;

  /// The tempo the reference timeline (and hence every `scoreMs`) was
  /// generated at. Playback MUST regenerate at this same BPM or the anchors
  /// describe a timeline that no longer exists.
  final int generationBpm;

  /// See [AutoAlignmentResult.hasCompressedAnchors] — surfaced to the user as
  /// [alignmentReviewMessage] rather than silently trusted.
  final bool hasCompressedAnchors;

  const MediaAlignment({
    required this.anchors,
    required this.generationBpm,
    this.hasCompressedAnchors = false,
  });
}

/// Persists alignments by [PieceMedia.alignmentKey], so alignment runs once
/// per timeline rather than once per thing you can press play on.
///
/// Replaces `AudioSyncAnchorsStore` and the anchor half of
/// `TeacherRecordingStore`, which held the same JSON under two different keys
/// for no reason beyond having been written at different times. The key is the
/// alignment key and not the media id precisely so a piece's `mix`, `melody`
/// and `chords` — three mixes of one session, one timeline — keep sharing a
/// single cached alignment, which is the behaviour the old store documented
/// and which would otherwise have been lost in the merge.
class MediaAlignmentStore {
  String _key(String alignmentKey) => 'mediaAlignment.$alignmentKey';

  Future<void> save(String alignmentKey, MediaAlignment alignment) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(alignmentKey),
      jsonEncode({
        'generationBpm': alignment.generationBpm,
        'hasCompressedAnchors': alignment.hasCompressedAnchors,
        'anchors': alignment.anchors
            .map((a) => {'scoreMs': a.scoreMs, 'audioSec': a.audioSec})
            .toList(),
      }),
    );
  }

  /// Null if this timeline has never been aligned, or its saved data can't be
  /// parsed — the two are treated identically, because re-running the
  /// alignment is the recovery for both and it is cheap and safe.
  Future<MediaAlignment?> load(String alignmentKey) async {
    final prefs = await SharedPreferences.getInstance();
    return decode(prefs.getString(_key(alignmentKey)));
  }

  /// The parse half of [load], exposed so [MediaMigration] can re-encode a
  /// legacy blob without going through a second store class.
  static MediaAlignment? decode(String? raw) {
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final anchors = (json['anchors'] as List)
          .cast<Map<String, dynamic>>()
          .map((a) => ScoreAudioAnchor(
                (a['scoreMs'] as num).toDouble(),
                (a['audioSec'] as num).toDouble(),
              ))
          .toList();
      // Fewer than two anchors can't define a segment to interpolate across,
      // so it is not a usable alignment however well-formed the JSON is.
      if (anchors.length < 2) return null;
      return MediaAlignment(
        anchors: anchors,
        generationBpm: json['generationBpm'] as int,
        // Entries cached before this field existed.
        hasCompressedAnchors: json['hasCompressedAnchors'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> clear(String alignmentKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(alignmentKey));
  }

  Future<bool> isAligned(String alignmentKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_key(alignmentKey));
  }
}
