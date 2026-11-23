import 'dart:math' as math;
import 'dart:typed_data';

import 'yin.dart';

/// A pitch reading at a point in a stream.
class PitchReading {
  const PitchReading(this.endSample, this.pitch, [this.bands]);

  /// Index, counted from the first sample ever added, of the sample just
  /// after the analysed frame. Divide by the sample rate for seconds.
  final int endSample;

  /// The estimate, or null when the frame was silent.
  final PitchEstimate? pitch;

  /// With [PitchTracker.probeHz] set: the frame's level at 1, 2 and 3 times
  /// that frequency (a Hann-windowed DFT bin each, in rms units).
  final Float64List? bands;
}

/// Cuts a continuous stream of samples into overlapping frames and runs a
/// [YinDetector] on each: one reading every [hopSize] samples, once the first
/// [frameSize] samples have arrived.
///
/// Accepts samples in chunks of any size, as microphone plugins deliver them.
class PitchTracker {
  /// [frameSize] defaults to [frameSizeFor] the [detector].
  PitchTracker(this.detector, {int? frameSize, this.hopSize = 512})
      : frameSize = frameSize ?? frameSizeFor(detector) {
    assert(hopSize > 0 && hopSize <= this.frameSize);
    if (this.frameSize < detector.minFrameLength) {
      throw ArgumentError.value(this.frameSize, 'frameSize',
          'must be at least the detector\'s minFrameLength (${detector.minFrameLength})');
    }
  }

  /// The frame a [detector] wants: 2048 samples (43 ms at 48 kHz), doubled
  /// until it holds the detector's [YinDetector.minFrameLength].
  ///
  /// So a violin, viola, mandolin or recorder range reads 2048-sample frames,
  /// and a cello's, which searches down to 43 Hz (a fifth under its C2), 4096.
  /// That is what bass tuners do too: a frame long enough for the lowest
  /// string, at the cost of a slower first reading (85 ms against 43 ms).
  ///
  /// Measured with `tool/low_register_probe.dart` (a harmonic C2 under white
  /// noise, the median over a second of readings): at about 34 dB SNR, 4096
  /// samples read C2 within 0.3 cents (p90), as 2048 do a violin's G3. At
  /// 20 dB a short window reads low notes sharp: +6 to +8 cents on C2 with a
  /// 2048-sample frame (and the floor raised to fit it), +1.4 to +3 at 4096,
  /// under half a cent on G3. 6144 or 8192 gain little more there.
  static int frameSizeFor(YinDetector detector) {
    var n = 2048;
    while (n < detector.minFrameLength) {
      n *= 2;
    }
    return n;
  }

  final YinDetector detector;
  final int frameSize, hopSize;

  /// A frequency to watch, or null. Each reading then carries the frame's
  /// level at its first three harmonics ([PitchReading.bands]). Two strings
  /// tuned a few cents apart both fall inside one such band, so its level
  /// swells and fades at their difference: a beat. The frame is short
  /// (43 ms at 48 kHz) and so the band wide (about ±45 Hz) enough to hold
  /// both strings, but narrow enough to keep the neighbouring notes out.
  double? get probeHz => _probeHz;
  set probeHz(double? hz) {
    if (hz == _probeHz) return;
    _probeHz = hz;
    _probe = null;
  }

  double? _probeHz;
  List<Float64List>? _probe; // per harmonic: cos, sin, windowed

  Float64List? _bands() {
    final hz = _probeHz;
    if (hz == null) return null;
    final n = frameSize;
    final probe = _probe ??= [
      for (var h = 1; h <= 3; h++)
        Float64List(2 * n)
          ..setAll(0, [
            for (var i = 0; i < n; i++)
              (0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1))) * math.cos(2 * math.pi * h * hz * i / detector.sampleRate),
            for (var i = 0; i < n; i++)
              (0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1))) * math.sin(2 * math.pi * h * hz * i / detector.sampleRate),
          ]),
    ];
    final out = Float64List(3);
    for (var h = 0; h < 3; h++) {
      final w = probe[h];
      var re = 0.0, im = 0.0;
      for (var i = 0; i < n; i++) {
        re += _frame[i] * w[i];
        im += _frame[i] * w[n + i];
      }
      // A sine of amplitude A, through a Hann window (which sums to n/2),
      // reads A/2 · n/2: so 4/n gives A, and 1/sqrt2 its rms.
      out[h] = math.sqrt(re * re + im * im) * 4 / n / math.sqrt2;
    }
    return out;
  }

  late final Float32List _frame = Float32List(frameSize);
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
          out.add(PitchReading(_total, detector.detect(_frame), _bands()));
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
          out.add(PitchReading(_total, detector.detect(_frame), _bands()));
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
