import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'audio_score_auto_aligner.dart';

/// Persists the result of one piece's automatic score-to-audio alignment
/// (see [AudioScoreAutoAligner]) so it only has to run once per device — a
/// SharedPreferences-backed JSON blob per piece.
///
/// Alignment always analyzes the piece's `melody` track (the closest match
/// to the score's own notes, and so the best-conditioned reference for
/// DTW) — NOT whichever track the user chooses to actually listen to. The
/// `mix`/`melody`/`chords` variants are different mixes of the same backing
/// recording session, so they share one timeline; one alignment, keyed only
/// by piece, serves playback of any of the three.
class AudioSyncAnchorsStore {
  String _key(String pieceId) => 'audioSyncAnchors.$pieceId';

  Future<void> save(
    String pieceId, {
    required List<ScoreAudioAnchor> anchors,
    required int generationBpm,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode({
      'generationBpm': generationBpm,
      'anchors': anchors
          .map((a) => {'scoreMs': a.scoreMs, 'audioSec': a.audioSec})
          .toList(),
    });
    await prefs.setString(_key(pieceId), json);
  }

  /// Returns null if this piece has never been aligned, or its saved data
  /// can't be parsed (treated the same as "never aligned" — re-running the
  /// alignment is cheap and safe).
  Future<({List<ScoreAudioAnchor> anchors, int generationBpm})?> load(
    String pieceId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(pieceId));
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
      if (anchors.length < 2) return null;
      return (anchors: anchors, generationBpm: json['generationBpm'] as int);
    } catch (_) {
      return null;
    }
  }

  Future<void> clear(String pieceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(pieceId));
  }

  Future<bool> isAligned(String pieceId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_key(pieceId));
  }
}
