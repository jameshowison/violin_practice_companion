import 'midi_generator.dart';
import 'playback_service_base.dart';

/// The Silent track: the score's clock and nothing else. The cursor, the
/// count-in's numbers and the loop run at the tempo on the phone's own clock;
/// no audio is made, so no speaker is held — an AirPlay or Bluetooth speaker
/// is left free (docs/rendered-score-plan.md, "Mute").
///
/// Not a muted player: AVPlayer's volume does nothing on AirPlay (Silent
/// played aloud on Kitchen, 2026-11-19), and with nothing heard there is
/// nothing for the cursor to keep in step with.
class SilentPlaybackService extends PlaybackServiceBase {
  SilentPlaybackService(super.generator);

  @override
  void onPlayStarted(MidiData data, double startOffsetSeconds) {}

  @override
  void onStopped() {}

  @override
  void onTick(double playbackTime, MidiData data) {}
}
