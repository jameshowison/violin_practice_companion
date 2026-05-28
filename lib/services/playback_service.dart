// Web uses Web Audio API oscillators; non-web uses flutter_midi_pro + SoundFont.
export 'playback_service_io.dart' if (dart.library.html) 'playback_service_web.dart';
