import 'package:string_tuner/string_tuner.dart';

import 'tuner_input_base.dart';

/// What the tuner screen shows.
class TunerReading {
  const TunerReading(this.string, this.cents, this.hz, {required this.live});

  final TunedString string;

  /// Smoothed; negative is flat.
  final double cents;
  final double hz;

  /// False while holding the last reading through a gap (a bow change, a
  /// pause between plucks).
  final bool live;
}

/// Turns microphone frames into the reading on screen.
///
/// - Frames under [minClarity] are ignored (noise, the scrape of a bow
///   change, two strings at once).
/// - [StringFollower] picks the string, unless one is [pinned].
/// - The cents shown are the median of the last [medianOf] readings: it
///   steadies the display without the lag of a long average, and ignores a
///   single wild frame.
/// - When the sound stops, the last reading stays for [holdFor], then the
///   tuner goes back to idle.
///
/// Time comes from the frames themselves, so tests can drive it exactly.
class TunerModel {
  TunerModel(InstrumentTuning tuning,
      {this.minClarity = 0.85,
      this.medianOf = 5,
      this.holdFor = const Duration(milliseconds: 1500)})
      : _follower = StringFollower(tuning);

  final double minClarity;
  final int medianOf;
  final Duration holdFor;

  StringFollower _follower;
  final _recent = <double>[];
  TunerReading? _reading;
  Duration? _lastHeard;
  Duration _now = Duration.zero;

  InstrumentTuning get tuning => _follower.tuning;

  /// A new instrument or reference pitch: starts afresh, keeping the pinned
  /// string by name if the new tuning has it.
  set tuning(InstrumentTuning t) {
    final pin = _follower.pinned?.name;
    _follower = StringFollower(t);
    pinned = pin;
    _clear();
  }

  /// The string picked on screen, by name (`'A4'`), or null to follow
  /// whatever is played.
  String? get pinned => _follower.pinned?.name;
  set pinned(String? name) {
    final next = name == null
        ? null
        : tuning.strings.where((s) => s.name == name).firstOrNull;
    if (next?.name == _follower.pinned?.name) return;
    _follower.pinned = next;
    _follower.reset();
    _clear();
  }

  /// The reading to show, or null when idle.
  TunerReading? get reading {
    final r = _reading;
    if (r == null || _lastHeard == null) return null;
    final quiet = _now - _lastHeard!;
    if (quiet > holdFor) return null;
    // Short dropouts (a frame or two under minClarity) are normal even on a
    // steady note; only a real gap dims the reading.
    return quiet > const Duration(milliseconds: 400)
        ? TunerReading(r.string, r.cents, r.hz, live: false)
        : r;
  }

  /// Takes one frame. Returns true when [reading] may have changed.
  bool add(TunerFrame f) {
    final before = reading;
    _now = f.at;
    final p = f.pitch;
    if (p != null && p.clarity >= minClarity) {
      final r = _follower.update(p.hz);
      if (_reading != null && _reading!.string.midi != r.string.midi) {
        _recent.clear();
      }
      _recent.add(r.cents);
      if (_recent.length > medianOf) _recent.removeAt(0);
      final sorted = [..._recent]..sort();
      final med = sorted[sorted.length ~/ 2];
      _reading = TunerReading(r.string, med, r.hz, live: true);
      _lastHeard = f.at;
      return true;
    }
    final after = reading;
    return (before == null) != (after == null) || before?.live != after?.live;
  }

  void _clear() {
    _recent.clear();
    _reading = null;
    _lastHeard = null;
  }
}
