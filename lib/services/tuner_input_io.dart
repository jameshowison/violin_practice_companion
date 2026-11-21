import 'dart:async';
import 'dart:isolate';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:pitch_tuner/pitch_tuner.dart';

import 'tuner_input_base.dart';

/// The tuner's microphone on iOS, Android and macOS: 48 kHz mono 16-bit PCM
/// from `record`, cut into frames and analysed by `pitch_tuner` on a
/// long-lived background isolate, so the YIN work (about 0.6 ms a frame,
/// ~90 frames a second) never lands on the UI thread.
///
/// ## The audio session (iOS)
///
/// The app runs in ONE session, set at launch (AudioCalibrationPlugin
/// .applyAppSession, mirrored in app_audio_session.dart). Left to itself,
/// `record` sets its own category and options on every start, which is a
/// session switch: the one that stops the synth's engines and blips AirPlay
/// volume (CLAUDE.md, "Audio on iOS"). So [start] turns that off with
/// `manageAudioSession(false)`, every time, because `record` turns it back on
/// in `dispose()`. It still sets a preferred sample rate (48 kHz, which the
/// hardware normally already runs at) and input channel count.
///
/// Echo cancellation, noise suppression and automatic gain are off: all three
/// bend a sustained tone. On Android the `mic` source is used, the least
/// processed one every device supports.
class TunerInput implements TunerInputBase {
  static const sampleRate = 48000;

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _pcm;
  Isolate? _worker;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  StreamController<TunerFrame>? _out;

  @override
  set onPcm(void Function(Uint8List pcm)? f) => _onPcm = f;
  void Function(Uint8List pcm)? _onPcm;

  @override
  set probeHz(double? hz) {
    _probeHz = hz;
    _toWorker?.send(hz ?? double.nan);
  }

  double? _probeHz;

  @override
  bool get isSupported => true;

  @override
  Future<Stream<TunerFrame>> start({required double minHz, required double maxHz}) async {
    await stop();
    final recorder = _recorder ??= AudioRecorder();
    if (!await recorder.hasPermission()) throw const TunerMicDenied();
    final ios = recorder.ios;
    if (ios != null) {
      await ios.manageAudioSession(false);
      // With management off, `record` doesn't activate the session either, and
      // until something has played the app's session is configured but
      // inactive: the input then reports 0 Hz and `record` fails with "Format
      // conversion is not possible". audio_session already holds the app's
      // exact configuration (app_audio_session.dart), so activating through it
      // changes nothing else; just_audio does the same on every play().
      try {
        await (await AudioSession.instance).setActive(true);
      } catch (e) {
        if (kDebugMode) debugPrint('[tuner] session activate failed: $e');
      }
    }

    // The worker first, so no audio arrives before it can take it.
    final fromWorker = ReceivePort();
    _fromWorker = fromWorker;
    _worker = await Isolate.spawn(
      _workerMain,
      (fromWorker.sendPort, sampleRate.toDouble(), minHz, maxHz),
      debugName: 'tuner',
    );
    final out = StreamController<TunerFrame>();
    _out = out;
    final ready = Completer<SendPort>();
    fromWorker.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
      } else if (msg is Float64List) {
        // [endSample, hz, clarity, rms, band1..3] per reading; hz is NaN when
        // silent, band1 when there is no probe.
        for (var i = 0; i + 6 < msg.length; i += 7) {
          final at = Duration(microseconds: (msg[i] * 1e6 / sampleRate).round());
          final hz = msg[i + 1];
          out.add(TunerFrame(
              at,
              hz.isNaN
                  ? null
                  : PitchEstimate(hz: hz, clarity: msg[i + 2], rms: msg[i + 3]),
              msg[i + 4].isNaN ? null : [msg[i + 4], msg[i + 5], msg[i + 6]]));
        }
      }
    });
    _toWorker = await ready.future;
    if (_probeHz != null) _toWorker!.send(_probeHz!);

    final pcm = await recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: sampleRate,
      numChannels: 1,
      autoGain: false,
      echoCancel: false,
      noiseSuppress: false,
      androidConfig: AndroidRecordConfig(audioSource: AndroidAudioSource.mic),
    ));
    _pcm = pcm.listen(
      (chunk) {
        _onPcm?.call(chunk);
        _toWorker?.send(TransferableTypedData.fromList([chunk]));
      },
      onError: (Object e) {
        if (kDebugMode) debugPrint('[tuner] mic stream error: $e');
        out.addError(e);
      },
    );
    return out.stream;
  }

  @override
  Future<void> stop() async {
    await _pcm?.cancel();
    _pcm = null;
    try {
      await _recorder?.stop();
    } catch (e) {
      if (kDebugMode) debugPrint('[tuner] stop failed (ignored): $e');
    }
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _toWorker = null;
    _fromWorker?.close();
    _fromWorker = null;
    // Not awaited: close() waits for its listener to see the done event, and
    // the listener has usually cancelled already, so it would never return,
    // and the next start() would hang in here.
    _out?.close();
    _out = null;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _recorder?.dispose();
    _recorder = null;
  }
}

/// The background isolate: PCM chunks in, packed readings out.
void _workerMain((SendPort, double, double, double) args) {
  final (toMain, sampleRate, minHz, maxHz) = args;
  final tracker = PitchTracker(
    YinDetector(sampleRate: sampleRate, minHz: minHz, maxHz: maxHz),
    frameSize: 2048,
    hopSize: 512,
  );
  final inbox = ReceivePort();
  toMain.send(inbox.sendPort);
  inbox.listen((msg) {
    if (msg is double) {
      tracker.probeHz = msg.isNaN ? null : msg;
      return;
    }
    if (msg is! TransferableTypedData) return;
    final readings = tracker.addPcm16(msg.materialize().asUint8List());
    if (readings.isEmpty) return;
    final packed = Float64List(readings.length * 7);
    for (var i = 0; i < readings.length; i++) {
      final p = readings[i].pitch, b = readings[i].bands;
      packed[7 * i] = readings[i].endSample.toDouble();
      packed[7 * i + 1] = p?.hz ?? double.nan;
      packed[7 * i + 2] = p?.clarity ?? 0;
      packed[7 * i + 3] = p?.rms ?? 0;
      for (var h = 0; h < 3; h++) {
        packed[7 * i + 4 + h] = b?[h] ?? double.nan;
      }
    }
    toMain.send(packed);
  });
}
