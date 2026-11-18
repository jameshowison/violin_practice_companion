// Pure Dart, so tool/replay_tuner_session.dart judges exactly as the screen does.
import 'dart:math' as math;

/// What a frame meant to [UnisonMeter.add].
enum UnisonEvent { none, plucked, judged }

/// What one pluck of both strings of a mandolin course said about them.
class UnisonVerdict {
  const UnisonVerdict({required this.beatHz, required this.cents, required this.strength});

  /// The beat heard, in Hz: how far apart the two strings are.
  final double beatHz;

  /// The same as cents between the two strings, at the course's pitch.
  final double cents;

  /// How deep the beat is, in dB: the swell and fade of the level, averaged
  /// over the harmonics that rang long enough to measure.
  final double strength;

  /// A shallow beat, or one too slow to tell from none: the pair sounds as
  /// one. Too slow is under [UnisonMeter.togetherCents] apart, or a beat
  /// slower than [UnisonMeter.togetherHz] whatever the cents: one swell in
  /// 1.7 s is less than a pluck's ring can show, to the meter or the ear. At
  /// G that is 5 cents, and a 3-cent rule alone sent a G pair back three
  /// times running though each string had just said "In tune!" alone
  /// (2026-11-17).
  bool get together =>
      cents < UnisonMeter.togetherCents ||
      beatHz < UnisonMeter.togetherHz ||
      strength < UnisonMeter.togetherStrength;

  @override
  String toString() =>
      '${together ? 'together' : 'beating'} ${beatHz.toStringAsFixed(2)} Hz = ${cents.toStringAsFixed(1)}¢, '
      '${strength.toStringAsFixed(2)} dB';
}

/// Listens for beats between the two strings of a mandolin course, plucked
/// together.
///
/// Two strings f and f+Δ sound, at the course's pitch, like one note whose
/// loudness swells and fades Δ times a second; at the second harmonic 2Δ,
/// at the third 3Δ. So from each frame's level at the course's first three
/// harmonics (PitchTracker.probeHz), over one pluck: the decay is taken out
/// (a quadratic in dB), and the one Δ whose multiples best explain what is
/// left is the beat. Needing the three to agree is what tells two strings
/// apart from a single one wobbling for some other reason (a hand on the
/// tuner, the player talking).
///
/// A beat slower than [minHz] cannot be told from none in one pluck's ring,
/// which is what a player hears too: a pair that slow sounds together.
class UnisonMeter {
  UnisonMeter({
    this.skip = const Duration(milliseconds: 200),
    this.minRing = const Duration(milliseconds: 1400),
    this.maxRing = const Duration(milliseconds: 2600),
  });

  /// Left out after the pluck: the pick's own noise.
  final Duration skip;

  /// The least ring that gives a verdict, and the most that is waited for.
  final Duration minRing, maxRing;

  static const minHz = 0.3, maxHz = 6.0;
  static const togetherCents = 3.0, togetherHz = 0.6, togetherStrength = 0.6;

  Duration? _start; // the pluck being judged, or the last judged
  double _peak = 0; // the loudest since the last pluck (three bands summed)
  final _recent = <List<double>>[]; // the three bands, the last 20 frames
  bool _quiet = true; // died away since the last pluck
  Duration? _onset; // heard after the quiet: a pluck if it grows loud enough
  int _onsetFrames = 0;
  final _t = <double>[];
  final _bands = <List<double>>[[], [], []];
  UnisonVerdict? _verdict;
  bool _done = true;

  /// Forget the pluck, as when the string or course changes: the next onset
  /// is a pluck.
  void reset() {
    _start = null;
    _done = true;
    _verdict = null;
    _quiet = true;
    _peak = 0;
    _onset = null;
    _recent.clear();
  }

  /// A pluck is ringing and has not been judged yet.
  bool get waiting => _start != null && !_done;

  /// The last pluck's verdict, once it has rung long enough (or stopped);
  /// null until then, and null too if it was too short to say.
  UnisonVerdict? get verdict => _verdict;

  /// One frame's levels at the course's harmonics ([bands]: 1st, 2nd, 3rd),
  /// and whether the tuner heard an [onset] in it. Says when this frame
  /// was a new pluck, and when it decided one. With [judge] off it only
  /// follows the plucks (to say when the next one comes), judging none.
  ///
  /// What a pluck is, it decides for itself. Two strings beating deeply all
  /// but vanish at each beat and swell back, and the tuner takes each swell
  /// for a new note. So an onset is a pluck only once the last one has died
  /// away; while it rings, a pluck is a jump back near the last pluck's peak
  /// in all three harmonics at once. A beat swells them at different times
  /// (Δ, 2Δ, 3Δ a second), and a pick wakes them together: a G pair beating
  /// 2 Hz, its fundamental weak, swelled back past twice its last null at
  /// every beat and restarted the wait thirteen times running.
  UnisonEvent add(Duration at, List<double> bands,
      {required double courseHz, bool onset = false, bool judge = true}) {
    final level = bands[0] + bands[1] + bands[2];
    final s0 = _start;
    var jumped = s0 != null &&
        at - s0 > const Duration(milliseconds: 500) &&
        _recent.length >= 10 &&
        level > 0.6 * _peak;
    for (var h = 0; h < 3 && jumped; h++) {
      final low = _recent.sublist(_recent.length - 10).map((r) => r[h]).reduce(math.min);
      jumped = bands[h] > 2 * low;
    }
    _recent.add([bands[0], bands[1], bands[2]]);
    if (_recent.length > 20) _recent.removeAt(0);
    // Quiet: 20 dB down for 0.2 s. After that, an onset is a pluck once it
    // is loud: within a few frames, back to at least 30% (10 dB down) of the
    // last pluck's peak (any level, if none). A swell in a tail that has
    // fallen 20 dB never gets near that.
    if (_peak > 0 && _recent.length == 20 && _recent.map((r) => r[0] + r[1] + r[2]).reduce(math.max) < _peak / 10) {
      _quiet = true;
    }
    if (onset && _quiet && _onset == null) {
      _onset = at;
      _onsetFrames = 0;
    }
    var plucked = jumped;
    final o = _onset;
    if (o != null) {
      if (_start == null || level >= 0.3 * _peak) {
        plucked = true;
      } else if (++_onsetFrames > 6) {
        _onset = null;
      }
    }
    if (plucked) {
      _start = jumped ? at : (o ?? at);
      _onset = null;
      _peak = level;
      _quiet = false;
      _t.clear();
      for (final b in _bands) {
        b.clear();
      }
      _verdict = null;
      _done = !judge;
      return UnisonEvent.plucked;
    }
    _peak = math.max(_peak, level);
    final s = _start;
    if (s == null || _done) return UnisonEvent.none;
    final t = (at - s).inMicroseconds / 1e6;
    final b1 = _bands[0];
    if (t >= skip.inMicroseconds / 1e6) {
      _t.add(t);
      for (var h = 0; h < 3; h++) {
        _bands[h].add(bands[h]);
      }
    }
    final rung = at - s;
    if (rung < minRing || b1.isEmpty) return UnisonEvent.none;
    // Rung long enough: judge when the fundamental has died away, or at
    // maxRing. Died away over the last 0.4 s, not in one frame: two strings
    // a little apart all but cancel at each beat.
    final peak = b1.reduce(math.max);
    final recent = b1.sublist(math.max(0, b1.length - 38)).reduce(math.max);
    if (rung < maxRing && recent > peak / 30) return UnisonEvent.none;
    _done = true;
    _verdict = measure(_t, _bands, courseHz: courseHz);
    return UnisonEvent.judged;
  }

  /// The beat in one pluck: [t] seconds since the pluck, [bands] each
  /// harmonic's level at those times.
  static UnisonVerdict? measure(List<double> t, List<List<double>> bands, {required double courseHz}) {
    final series = <(int, List<double>, List<double>)>[];
    for (var h = 0; h < bands.length; h++) {
      final b = bands[h];
      if (b.isEmpty) continue;
      final peak = b.reduce(math.max);
      if (peak <= 0) continue;
      // From the start until the harmonic has died away for good (it dips
      // at every beat on the way), each level no lower than 40 dB down, so a
      // beat's near-silence counts as deep, not as bottomless.
      var n = b.length;
      while (n > 0 && b[n - 1] <= peak / 30) {
        n--;
      }
      if (n < 50) continue;
      final x = [for (var i = 0; i < n; i++) t[i] - t[0]];
      final y = [for (var i = 0; i < n; i++) 20 * math.log(math.max(b[i], peak / 100)) / math.ln10];
      series.add((h + 1, x, _detrend(x, y)));
    }
    if (series.isEmpty) return null;
    var best = 0.0, bestHz = minHz;
    for (var d = minHz; d <= maxHz + 1e-9; d += 0.02) {
      var sum = 0.0;
      for (final (h, x, r) in series) {
        final w = 2 * math.pi * h * d;
        var re = 0.0, im = 0.0;
        for (var i = 0; i < x.length; i++) {
          re += r[i] * math.cos(w * x[i]);
          im -= r[i] * math.sin(w * x[i]);
        }
        sum += math.sqrt(re * re + im * im) * 2 / x.length;
      }
      if (sum / series.length > best) {
        best = sum / series.length;
        bestHz = d;
      }
    }
    return UnisonVerdict(
        beatHz: bestHz, cents: 1200 * math.log(1 + bestHz / courseHz) / math.ln2, strength: best);
  }

  /// [y] less its least-squares quadratic in [x]: the decay taken out.
  static List<double> _detrend(List<double> x, List<double> y) {
    // Normal equations for a + b x + c x².
    final s = List.filled(5, 0.0), r = List.filled(3, 0.0);
    for (var i = 0; i < x.length; i++) {
      var p = 1.0;
      for (var k = 0; k < 5; k++) {
        s[k] += p;
        if (k < 3) r[k] += p * y[i];
        p *= x[i];
      }
    }
    final m = [
      [s[0], s[1], s[2], r[0]],
      [s[1], s[2], s[3], r[1]],
      [s[2], s[3], s[4], r[2]],
    ];
    for (var c = 0; c < 3; c++) {
      var p = c;
      for (var i = c + 1; i < 3; i++) {
        if (m[i][c].abs() > m[p][c].abs()) p = i;
      }
      final tmp = m[c];
      m[c] = m[p];
      m[p] = tmp;
      if (m[c][c].abs() < 1e-12) return [for (final v in y) v - y.first];
      for (var i = 0; i < 3; i++) {
        if (i == c) continue;
        final f = m[i][c] / m[c][c];
        for (var k = c; k < 4; k++) {
          m[i][k] -= f * m[c][k];
        }
      }
    }
    final a = m[0][3] / m[0][0], b = m[1][3] / m[1][1], c = m[2][3] / m[2][2];
    return [for (var i = 0; i < x.length; i++) y[i] - (a + b * x[i] + c * x[i] * x[i])];
  }
}
