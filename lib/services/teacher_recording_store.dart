import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'audio_score_auto_aligner.dart';

/// Persists a user-recorded "teacher demo" for one piece: the recorded
/// video/audio file paths, the wall-clock offset between when each recording
/// actually started (see teacher_recording_capture_io.dart), and the DTW
/// alignment computed from the audio against the score.
///
/// Deliberately separate from [AudioSyncAnchorsStore] (bundled Play Along
/// tracks) rather than sharing it — same anchor JSON shape, but this store
/// additionally owns user-generated file paths and an AV offset that bundled
/// tracks have no use for, and a piece can have both a bundled Play Along
/// track and a recorded teacher demo at once.
class TeacherRecordingStore {
  String _key(String pieceId) => 'teacherRecording.$pieceId';

  Future<void> save(
    String pieceId, {
    required String videoPath,
    required String audioPath,
    required int avOffsetMs,
    required List<ScoreAudioAnchor> anchors,
    required int generationBpm,
    required bool hasCompressedAnchors,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode({
      'videoPath': videoPath,
      'audioPath': audioPath,
      'avOffsetMs': avOffsetMs,
      'generationBpm': generationBpm,
      'hasCompressedAnchors': hasCompressedAnchors,
      'anchors': anchors
          .map((a) => {'scoreMs': a.scoreMs, 'audioSec': a.audioSec})
          .toList(),
    });
    await prefs.setString(_key(pieceId), json);
  }

  /// Returns null if this piece has no teacher recording yet, or its saved
  /// data can't be parsed (treated the same as "none" — re-recording is the
  /// only recovery, same policy as `AudioSyncAnchorsStore.load`).
  Future<
      ({
        String videoPath,
        String audioPath,
        int avOffsetMs,
        List<ScoreAudioAnchor> anchors,
        int generationBpm,
        bool hasCompressedAnchors,
      })?> load(String pieceId) async {
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
      return (
        videoPath: json['videoPath'] as String,
        audioPath: json['audioPath'] as String,
        avOffsetMs: json['avOffsetMs'] as int,
        anchors: anchors,
        generationBpm: json['generationBpm'] as int,
        hasCompressedAnchors: json['hasCompressedAnchors'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> clear(String pieceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(pieceId));
  }

  Future<bool> has(String pieceId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_key(pieceId));
  }
}
