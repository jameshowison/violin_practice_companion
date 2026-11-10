import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

/// Tells `audio_session` about the session the app already runs in, before
/// anything plays.
///
/// The app sets ONE iOS session at launch and keeps it
/// (`AudioCalibrationPlugin.applyAppSession`, called from AppDelegate):
/// play-and-record, A2DP + AirPlay, default to speaker. But just_audio calls
/// `AudioSession.setActive` on every `play()`, and while `audio_session` has
/// no configuration of its own that applies its fallback,
/// `AudioSessionConfiguration.music()` — category `.playback`. So the first
/// thing played after each launch (or hot restart) silently switched the app
/// to `.playback` at 44.1kHz, and the next calibration switched it back.
///
/// Measured on Hazel iPad over AirPlay (sync_cal trace): each switch
/// reconfigured all 16 of the synth's AVAudioEngines — which stop and are
/// never restarted by flutter_midi_pro, so the score went silent — and blipped
/// the speaker's volume (0.9 → 0.3 → 0.9 on one speaker; to zero on a Sonos
/// Roam).
///
/// Options must match the native ones exactly, or this itself is a switch.
/// Android keeps `.music()`'s attributes, which is what it got before.
Future<void> configureAppAudioSession() async {
  try {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music().copyWith(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.allowBluetoothA2dp |
              AVAudioSessionCategoryOptions.allowAirPlay |
              AVAudioSessionCategoryOptions.defaultToSpeaker,
      avAudioSessionMode: AVAudioSessionMode.defaultMode,
    ));
  } catch (e) {
    debugPrint('[audio_session] configure failed: $e');
  }
}
