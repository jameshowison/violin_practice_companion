// The tuner's developer session recording: the microphone's audio and what
// the tuner made of each frame, written to the documents directory for
// `scripts/pull_tuner_sessions.sh` and `tool/replay_tuner_session.dart`.
// Off unless switched on (long-press the tuner's title). No file system on
// the web, so nothing is recorded there.
export 'tuner_recording_io.dart' if (dart.library.html) 'tuner_recording_web.dart';

/// `tuner.recordSessions`: the developer switch.
const tunerRecordSessionsKey = 'tuner.recordSessions';
