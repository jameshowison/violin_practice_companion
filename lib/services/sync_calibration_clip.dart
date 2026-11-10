// The calibration clip is played from a file, like a recording, so it goes
// through exactly the player path being calibrated. The web build has no file
// system to put it in (and no mic capture), so there it is unavailable.
export 'sync_calibration_clip_io.dart'
    if (dart.library.html) 'sync_calibration_clip_web.dart';
