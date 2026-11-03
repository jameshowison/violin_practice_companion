// The tray's shared tempo presets applied to a recording: its own tempo is
// measured from its anchors, and the preset bpm becomes a playback rate.
import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/audio_score_auto_aligner.dart';
import 'package:violin_practice_companion/services/media_playback_service.dart';

void main() {
  group('recordingBpmFrom', () {
    test('score span over audio span, scaled by the generation bpm', () {
      // Generated at 60 bpm: 16 s of score is 16 beats. Played in 8 s → 120.
      const anchors = [
        ScoreAudioAnchor(0, 5.0),
        ScoreAudioAnchor(8000, 9.0),
        ScoreAudioAnchor(16000, 13.0),
      ];
      expect(MediaPlaybackService.recordingBpmFrom(anchors, 60), 120);
    });

    test('a lead-in before the first anchor does not slow the estimate', () {
      const late = [ScoreAudioAnchor(0, 30.0), ScoreAudioAnchor(10000, 40.0)];
      expect(MediaPlaybackService.recordingBpmFrom(late, 80), 80);
    });

    test('null when there is nothing to measure', () {
      expect(MediaPlaybackService.recordingBpmFrom(const [], 80), isNull);
      expect(
          MediaPlaybackService.recordingBpmFrom(
              const [ScoreAudioAnchor(0, 1)], 80),
          isNull);
      expect(
          MediaPlaybackService.recordingBpmFrom(
              const [ScoreAudioAnchor(0, 1), ScoreAudioAnchor(1000, 2)], 0),
          isNull);
    });
  });

  group('speedFor', () {
    test('preset bpm over recording bpm', () {
      expect(MediaPlaybackService.speedFor(80, 100), closeTo(0.8, 1e-9));
      expect(MediaPlaybackService.speedFor(100, 100), 1.0);
    });

    test('clamped to the usable time-stretch range', () {
      expect(MediaPlaybackService.speedFor(40, 200), MediaPlaybackService.minSpeed);
      expect(MediaPlaybackService.speedFor(208, 60), MediaPlaybackService.maxSpeed);
    });

    test('an unaligned recording plays at its own speed', () {
      expect(MediaPlaybackService.speedFor(60, null), 1.0);
    });
  });
}
