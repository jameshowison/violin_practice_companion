// iOS/Android shows the real draggable video window; web is a stub (see
// services/teacher_recording_capture_base.dart for why the whole feature is
// gated).
export 'floating_video_overlay_io.dart'
    if (dart.library.html) 'floating_video_overlay_web.dart';
