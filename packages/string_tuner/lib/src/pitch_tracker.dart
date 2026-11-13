import 'dart:typed_data';

import 'yin.dart';

/// A pitch reading at a point in a stream.
class PitchReading {
  const PitchReading(this.endSample, this.pitch);

  /// Index, counted from the first sample ever added, of the sample just
  /// after the analysed frame. Divide by the sample rate for seconds.
  final int endSample;

  /// The estimate, or null when the frame was silent.
  final PitchEstimate? pitch;
}

/// Cuts a continuous stream of samples into overlapping frames and runs a
/// [YinDetector] on each: one reading every [hopSize] samples, once the first
/// [frameSize] samples have arrived.
///
/// Accepts samples in chunks of any size, as microphone plugins deliver them.
class PitchTracker {
  PitchTracker(this.detector, {this.frameSize = 2048, this.hopSize = 512})
      : assert(hopSize > 0 && hopSize <= frameSize),
        _frame = Float32List(frameSize) {
    if (frameSize < detector.minFrameLength) {
      throw ArgumentError.value(frameSize, 'frameSize',
          'must be at least the detector\'s minFrameLength (${detector.minFrameLength})');
    }
  }

  final YinDetector detector;
  final int frameSize, hopSize;

  final Float32List _frame;
  int _filled = 0; // samples in _frame, up to frameSize
  int _sinceLast = 0; // samples slid in since the last reading
  int _total = 0;

  /// Clears the buffered audio, as after a pause in capture.
  void reset() {
    _filled = 0;
    _sinceLast = 0;
  }

  /// Adds float samples (nominally −1..1) and returns the readings they
  /// complete, oldest first.
  List<PitchReading> addSamples(Float32List samples) {
    final out = <PitchReading>[];
    var i = 0;
    while (i < samples.length) {
      final left = samples.length - i;
      if (_filled < frameSize) {
        // Still filling the first frame: a reading when it is full.
        final take = left < frameSize - _filled ? left : frameSize - _filled;
        _frame.setRange(_filled, _filled + take, samples, i);
        _filled += take;
        i += take;
        _total += take;
        if (_filled == frameSize) {
          out.add(PitchReading(_total, detector.detect(_frame)));
          _sinceLast = 0;
        }
      } else {
        // Full: slide the frame along, a reading every hopSize samples.
        final room = hopSize - _sinceLast;
        final take = left < room ? left : room;
        _frame.setRange(0, frameSize - take, _frame, take);
        _frame.setRange(frameSize - take, frameSize, samples, i);
        _sinceLast += take;
        i += take;
        _total += take;
        if (_sinceLast == hopSize) {
          out.add(PitchReading(_total, detector.detect(_frame)));
          _sinceLast = 0;
        }
      }
    }
    return out;
  }

  /// Adds signed 16-bit PCM, mono, as bytes (the format of `record`'s
  /// `startStream` with `AudioEncoder.pcm16bits`).
  List<PitchReading> addPcm16(Uint8List bytes, {Endian endian = Endian.little}) =>
      addSamples(pcm16ToFloat32(bytes, endian: endian));
}

/// Converts signed 16-bit PCM bytes to float samples in −1..1. A trailing odd
/// byte is ignored.
Float32List pcm16ToFloat32(Uint8List bytes, {Endian endian = Endian.little}) {
  final view = ByteData.sublistView(bytes);
  final n = bytes.length ~/ 2;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = view.getInt16(2 * i, endian) / 32768.0;
  }
  return out;
}
