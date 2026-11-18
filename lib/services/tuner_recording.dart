// The tuner's developer session recording: the microphone's audio and what
// the tuner made of each frame, written to the documents directory for
// `scripts/pull_tuner_sessions.sh` and `tool/replay_tuner_session.dart`.
// Off unless switched on (long-press the tuner's title), and only in builds
// made with --dart-define=TUNER_RECORDING=true (kTunerRecording).
export 'tuner_recording_io.dart';

/// `tuner.recordSessions`: the developer switch.
const tunerRecordSessionsKey = 'tuner.recordSessions';
