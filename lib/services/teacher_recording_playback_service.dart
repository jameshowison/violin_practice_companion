// iOS/Android drives real file playback; web is a stub (see
// teacher_recording_capture_base.dart for why the whole feature is gated).
export 'teacher_recording_playback_service_io.dart'
    if (dart.library.html) 'teacher_recording_playback_service_web.dart';
