import 'dart:math' as math;

import 'package:string_tuner/string_tuner.dart';

import 'tuner_input_base.dart';

/// Which way the last change of tuning went, measured on the |cents| from
/// the target: what lets the tuner say "Wrong way!" while there is still
/// time to turn back.
enum TunerTrend {
  /// Nothing to compare with yet, or no real change.
  none,

  /// Nearer the target than before: keep going.
  closer,

  /// Further out on the same side: turning the wrong way.
  wrongWay,

  /// Across the target and out the other side: back a little.
  overshot,
}

/// What [TunerModel.add] did with a frame, for the session recording.
enum TunerDecision {
  /// Too quiet to analyse.
  silent,

  /// Under [TunerModel.minClarity].
  unclear,

  /// Clear, but no note has started.
  noNote,

  /// In the first [TunerModel.attack] of a note.
  attack,

  /// More than 18 dB under the note's peak.
  tail,

  /// 8 dB under the last 300 ms: a beat's null, a bow change.
  dip,

  /// Too far from the note's pitch (an octave slip), or one of a run.
  outlier,

  /// Taken into the note's pitch.
  accepted,
}

/// What the tuner screen shows.
class TunerReading {
  const TunerReading(this.string, this.cents, this.hz,
      {required this.live, bool? inTune, this.trend = TunerTrend.none})
      : _inTune = inTune; // ignore: prefer_initializing_formals

  final TunedString string;

  /// Settled pitch of the note being played (or just played); negative is
  /// flat.
  final double cents;
  final double hz;

  /// False once the note has stopped: the reading is then the pose of the
  /// last pluck or bow, held until the next one.
  final bool live;

  final bool? _inTune;

  /// In tune, with hysteresis: in at ±[TunerModel.inTuneCents], out only past
  /// ±[TunerModel.outOfTuneCents], so a reading on the edge doesn't flicker
  /// between "In tune!" and advice. Without a model, just ±3.
  bool get inTune => _inTune ?? cents.abs() <= TunerModel.inTuneCents;

  final TunerTrend trend;
}

/// Turns microphone frames into the reading on screen, one NOTE at a time.
///
/// A plucked string does not hold a pitch: its attack is sharp (a big pluck
/// stretches the string, and the pitch falls back as it decays), and it
/// fades into the room's noise. A mandolin's course is two strings that are
/// never quite in unison, so it beats: once a second for 4 cents at A, and
/// in each null of the beat the pitch reads wild or locks onto a
/// subharmonic (an octave or a twelfth down) with clarity to spare. Read
/// frame by frame, the tuner flickers. So each note is read as a whole:
///
/// - A note starts at an onset: the level at least doubling over its
///   recent minimum, and (while a note rings) rising past what it has been
///   ringing at. A beat's recovery and a bow change come back to the old
///   level, not past it, so they continue the note.
/// - The first [attack] of a note is skipped: the pluck's sharp glide, the
///   scrape of the bow starting.
/// - Frames under [minClarity], more than 18 dB under the note's peak (its
///   fading tail), or 8 dB under the last 300 ms (a beat's null, a bow
///   change), are ignored.
/// - Frames more than [outlierCents] from the note's own pitch are ignored
///   (an octave slip), unless a dozen agree and hold steady (within
///   [strayCents]): a slur to another string, or a peg turned a long way,
///   starts a new note there. A voice glides; it does not.
/// - A note shows only once it has [minNoteFrames] accepted frames (~0.2 s):
///   a bow or a pluck has many more, a knock or a brushed string a handful.
///   Until then the last note's pose holds.
/// - Frames more than [belowLowest] cents under the lowest string are not a
///   string at all (talking, a knock), whatever their clarity.
/// - The note's pitch is the median of what was accepted in its last
///   [window]: steady, and nearer the settled end of a pluck than its
///   sharp start.
/// - When the note stops, its last reading stays (not [TunerReading.live])
///   for [holdFor]: the stringling keeps the pose of the last pluck, and
///   with it the advice, until the next one.
///
/// - A note that ended in tune is held only for [inTuneHoldFor]: there is
///   nothing left to do with it, so the screen goes back to waiting.
///
/// It also says which way the tuning is going ([TunerReading.trend]),
/// between notes (this pluck against the last one, on the same string) and,
/// for a held note that does not fade (a bow), within it (now against
/// [trendAfter] ago). Notes are compared at the same age, [settleAfter] in
/// (or at the end, if shorter): by then a pluck's glide is mostly gone, and
/// what is left is much the same in both, so it cancels. At 700 ms a hard
/// pluck and a gentle one of the same pitch still differed by 4¢. Compared early, the
/// glide would make a flat string look as if it were going the wrong way.
/// Within a bow the trend is taken afresh every frame, never from its first
/// 250 ms (the bow's scrape starts it flat), so "Wrong way!" goes as soon as
/// the turning does. Within [trendFloor] of the target there is no trend:
/// a bow wobbles by that much on its own, and "Flat"/"Sharp" already says
/// which way to go.
///
/// Time comes from the frames themselves, so tests can drive it exactly.
class TunerModel {
  /// What the last frame was taken as, and whether it started a note.
  TunerDecision lastDecision = TunerDecision.silent;
  bool lastOnset = false;

  TunerModel(InstrumentTuning tuning,
      {this.minClarity = 0.85,
      this.attack = const Duration(milliseconds: 100),
      this.window = const Duration(milliseconds: 400),
      this.holdFor = const Duration(seconds: 20),
      this.outlierCents = 60,
      this.trendCents = 4,
      this.trendAfter = const Duration(milliseconds: 600),
      this.settleAfter = const Duration(milliseconds: 900)})
      : _follower = StringFollower(tuning);

  /// "In tune!" within this many cents, after [inTuneFor] there.
  static const inTuneCents = 3.0;

  /// And stays in tune until past this.
  static const outOfTuneCents = 5.0;

  /// How long a live note must sit within [inTuneCents] to count (and a
  /// pluck must first have settled: see [TunerModel]'s _mayEnterInTune).
  static const inTuneFor = Duration(milliseconds: 150);

  /// No accepted frame for this long ends the note.
  static const noteGap = Duration(milliseconds: 400);

  /// How long a note that ended in tune is held before going idle.
  static const inTuneHoldFor = Duration(seconds: 3);

  /// Accepted frames a note needs before it is shown. In a session on the
  /// phone every real note had 83 or more, and every stray sound 13 or fewer.
  static const minNoteFrames = 20;

  /// No trend this near the target: within a bow's own wobble.
  static const trendFloor = 8.0;

  /// The dozen outliers that start a new note must lie within this of each
  /// other. A peg turned while bowing moves ~13¢ in their 128 ms; a voice
  /// gliding moved 36¢.
  static const strayCents = 20.0;

  /// How near an octave or a twelfth from the picked string (or the note
  /// being read) a pitch must be to be taken for the detector slipping to a
  /// harmonic. Wider than any tuning gets; narrower than the 200 cents
  /// between an octave and the next string.
  static const harmonicCents = 150.0;

  /// Further than this under the lowest string is not a string: a G tuned
  /// down a major third is already far past anything a player does.
  static const belowLowest = 400.0;

  /// A bow's scrape: within-note trends are not measured from before this.
  /// Under [settleAfter] - [trendAfter], so a bow's own trend is ready just
  /// before the comparison with the last note, and that one never flashes up
  /// for a frame first.
  static const _bowScrape = Duration(milliseconds: 250);

  final double minClarity;
  final Duration attack, window, holdFor, trendAfter, settleAfter;
  final double outlierCents, trendCents;

  StringFollower _follower;
  Duration _now = Duration.zero;

  // Levels of recent frames (0 for silence), newest last: ~300 ms.
  final _levels = <double>[];
  static const _levelFrames = 28, _onsetFrames = 5;

  // The note.
  Duration? _start;
  double _peak = 0;
  final _accepted = <(Duration, double)>[]; // (at, pitch in cents from A4)
  int _noteFrames = 0; // accepted in this note, all told
  Duration? _noteLast; // this note's last accepted frame, shown or not
  double? _pitch; // median of the window, cents from A4
  Duration? _lastAccepted;
  final _history = <(Duration, double, double)>[]; // (at, pitch, level)
  final _stray = <double>[]; // consecutive outliers, cents from A4
  TunerTrend _withinTrend = TunerTrend.none;
  Duration? _withinNoneSince; // when the bow's own comparison last went quiet
  bool _withinSpoke = false; // the bow has had a trend of its own
  double? _settled; // cents at settleAfter
  Duration? _inSince;
  bool _inTune = false;
  TunedString? _string;

  // The last note that ended with a reading.
  ({int midi, double cents})? _previous;

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

  /// Another string with the same name: the other string of a mandolin's
  /// pair. Starts afresh, so its first pluck is not compared with the last
  /// string's ("Wrong way!" when nothing had been turned).
  void newString() {
    _follower.reset();
    _clear();
  }

  /// A note has begun and has not yet settled: a pluck's first
  /// [settleAfter], a bow until its level has held for 300 ms of readings
  /// (about 0.65 s in). Its reading so far is the sharp
  /// start of a pluck gliding down, so the screen says it is listening and
  /// keeps the last pose, rather than move with the glide and be chased.
  bool get listening {
    final start = _start, last = _noteLast;
    if (start == null || _now - start >= settleAfter) return false;
    if (last != null && _now - last > noteGap) return false;
    if (_history.isEmpty) return last != null || _now - start < attack + noteGap;
    return !_mayEnterInTune(_now);
  }

  /// The reading to show, or null when idle.
  TunerReading? get reading {
    final p = _pitch, s = _string, last = _lastAccepted;
    if (p == null || s == null || last == null) return null;
    final quiet = _now - last;
    if (quiet > holdFor) return null;
    if (_inTune && quiet > noteGap + inTuneHoldFor) return null;
    final hz = _hz(p);
    final cents = centsBetween(hz, s.hz);
    final live = quiet <= noteGap;
    final inTune = live ? _inTune : cents.abs() <= (_inTune ? outOfTuneCents : inTuneCents);
    return TunerReading(s, cents, hz,
        live: live,
        inTune: inTune,
        trend: inTune ? TunerTrend.none : _trend(cents, s, live: live));
  }

  /// Takes one frame. Returns true when [reading] may have changed.
  bool add(TunerFrame f) {
    final before = reading;
    _now = f.at;
    final p = f.pitch;
    final level = p?.rms ?? 0;
    lastOnset = false;
    lastDecision = p == null ? TunerDecision.silent : TunerDecision.unclear;
    final changed = p != null && p.clarity >= minClarity && _take(f.at, p, level);
    _levels.add(level);
    if (_levels.length > _levelFrames) _levels.removeAt(0);
    if (changed) return true;
    final after = reading;
    return (before == null) != (after == null) || before?.live != after?.live;
  }

  /// A clear frame: starts a note, or adds to one. True if it was accepted.
  bool _take(Duration at, PitchEstimate p, double level) {
    if (_isOnset(at, level)) {
      _begin(at);
      lastOnset = true;
    }
    final start = _start;
    lastDecision = TunerDecision.noNote;
    if (start == null) return false;
    _peak = math.max(_peak, level);
    lastDecision = TunerDecision.attack;
    if (at - start < attack) return false;
    final local = _levels.isEmpty ? level : math.max(level, _levels.reduce(math.max));
    lastDecision = level < _peak / 8 ? TunerDecision.tail : TunerDecision.dip;
    if (level < _peak / 8 || level < local / 2.5) return false;
    lastDecision = TunerDecision.outlier;

    if (centsBetween(p.hz, tuning.strings.first.hz) < -belowLowest) return false;
    // An overtone or undertone of the picked string (its octave, or the
    // twelfth a flat string's harmonics lean to), never the string: turning
    // a tuner can't move it that far. Read as the string, a G 60 cents flat
    // showed +1165, "Very sharp", the wrong way.
    final pin = _follower.pinned;
    if (pin != null && _harmonicOf(centsBetween(p.hz, pin.hz))) return false;
    final pc = 1200 * math.log(p.hz / 440) / math.ln2;
    // Against this note's own frames once it has some, shown or not;
    // before that, against the last note's.
    final pitch = _accepted.isEmpty ? _pitch : _median(_accepted);
    if (pitch != null && (pc - pitch).abs() > outlierCents) {
      // An octave slip, or the start of something new: a dozen that agree,
      // and hold steady.
      if (_stray.isNotEmpty && (pc - _stray.first).abs() > outlierCents / 2) _stray.clear();
      _stray.add(pc);
      if (_stray.length > 12) _stray.removeAt(0);
      if (_stray.length < 12) return false;
      final sorted = [..._stray]..sort();
      if (sorted.last - sorted.first > strayCents) return false;
      // Steady an octave or a twelfth away is the detector slipping to a
      // harmonic, not a new note.
      if (_harmonicOf(sorted[sorted.length ~/ 2] - pitch)) return false;
      final agreed = [..._stray];
      _begin(at, keepPeak: true);
      lastOnset = true;
      for (final c in agreed) {
        _accepted.add((at, c));
      }
      _noteFrames = agreed.length;
    } else {
      _stray.clear();
    }
    lastDecision = TunerDecision.accepted;

    _accepted.add((at, pc));
    while (_accepted.first.$1 < at - window) {
      _accepted.removeAt(0);
    }
    _noteLast = at;
    if (++_noteFrames < minNoteFrames) return false;
    _pitch = _median(_accepted);
    _lastAccepted = at;

    final r = _follower.update(p.hz);
    if (_string != null && _string!.midi != r.string.midi) {
      // A move to another string (when following): nothing to compare.
      _history.clear();
      _withinTrend = TunerTrend.none;
      _withinSpoke = false;
      _withinNoneSince = null;
      _settled = null;
      _previous = null;
      _inSince = null;
      _inTune = false;
    }
    _string = r.string;
    final cents = centsBetween(_hz(_pitch!), r.string.hz);
    if (_settled == null && at - _start! >= settleAfter) _settled = cents;
    _updateWithinTrend(at, cents);
    _updateInTune(at, cents);
    return true;
  }

  bool _isOnset(Duration at, double level) {
    if (_levels.isEmpty) return true;
    final recent = _levels.sublist(math.max(0, _levels.length - _onsetFrames));
    final rose = level > 2 * recent.reduce(math.min) + 1e-4;
    if (_start == null) return rose || _levels.last == 0;
    final last = _noteLast;
    final ended = last == null ? at - _start! > noteGap + attack : at - last > noteGap;
    if (ended) return rose;
    if (at - _start! < const Duration(milliseconds: 250)) return false;
    // Past what it has been ringing at, not just back to it.
    final earlier = _levels.sublist(0, math.max(0, _levels.length - _onsetFrames));
    final ringing = earlier.isEmpty ? 0.0 : earlier.reduce(math.max);
    return rose && level > 1.4 * ringing;
  }

  void _begin(Duration at, {bool keepPeak = false}) {
    // The note that ends, if it came to a reading, is the one to compare with.
    final s = _string, p = _pitch;
    if (s != null && p != null) {
      _previous = (midi: s.midi, cents: _settled ?? centsBetween(_hz(p), s.hz));
    }
    _start = at;
    if (!keepPeak) _peak = 0;
    _accepted.clear();
    _noteFrames = 0;
    _noteLast = null;
    _history.clear();
    _stray.clear();
    _withinTrend = TunerTrend.none;
    _withinSpoke = false;
    _withinNoneSince = null;
    _settled = null;
    _inSince = null;
    // _pitch, _lastAccepted and _string stay: the last pose holds until this
    // note has a reading of its own. _inTune too, so "In tune!" isn't lost
    // to a re-pluck of an in-tune string.
  }

  void _updateInTune(Duration at, double cents) {
    final a = cents.abs();
    if (_inTune) {
      if (a > outOfTuneCents) {
        _inTune = false;
        _inSince = null;
      }
      return;
    }
    if (a <= inTuneCents && _mayEnterInTune(at)) {
      _inSince ??= at;
      if (at - _inSince! >= inTuneFor) _inTune = true;
    } else {
      _inSince = null;
    }
  }

  /// Whether this note may be called in tune yet. A pluck glides down from
  /// sharp, so a string a little flat passes through in tune on its way: a
  /// pluck must wait until [settleAfter]. A note whose level holds (a bow)
  /// may once it has held for 300 ms.
  bool _mayEnterInTune(Duration at) {
    if (at - _start! >= settleAfter) return true;
    final then = _history.lastWhere((h) => h.$1 <= at - const Duration(milliseconds: 300),
        orElse: () => _history.first);
    if (at - then.$1 < const Duration(milliseconds: 300)) return false;
    return _history.last.$3 >= 0.9 * then.$3;
  }

  /// Within a note that does not fade (a bow): now against [trendAfter] ago.
  void _updateWithinTrend(Duration at, double cents) {
    final recent = _levels.sublist(math.max(0, _levels.length - 14));
    final level = ([...recent]..sort())[recent.length ~/ 2];
    _history.add((at, cents, level));
    final then = _history.lastWhere((h) => h.$1 <= at - trendAfter, orElse: () => _history.first);
    if (at - then.$1 < trendAfter) return;
    _history.removeWhere((h) => h.$1 < then.$1);
    // A pluck fades (by 20% or more over the interval); a bow holds.
    if (level < 0.8 * then.$3 || level < 0.5 * _peak) return;
    if (then.$1 - _start! < _bowScrape) return;
    final t = _compare(then.$2, cents);
    if (t != TunerTrend.none) {
      _withinTrend = t;
      _withinSpoke = true;
      _withinNoneSince = null;
    } else if (_withinTrend != TunerTrend.none) {
      // Cleared only once quiet for a moment, so it does not flicker.
      _withinNoneSince ??= at;
      if (at - _withinNoneSince! >= _bowScrape) _withinTrend = TunerTrend.none;
    }
  }

  TunerTrend _trend(double cents, TunedString s, {required bool live}) {
    // Once the bow has said which way it is going, the last note is stale.
    if (_withinSpoke) return _withinTrend;
    final prev = _previous;
    if (prev == null || prev.midi != s.midi) return TunerTrend.none;
    final now = _settled ?? (live ? null : cents);
    return now == null ? TunerTrend.none : _compare(prev.cents, now);
  }

  TunerTrend _compare(double before, double now) {
    if (now.abs() < trendFloor) return TunerTrend.none;
    // Overshot only from clearly off the other side: from the edge of in
    // tune it would flicker with every frame, and wrong way says it as well.
    if (before.abs() >= trendFloor && before.sign != now.sign) return TunerTrend.overshot;
    final d = now.abs() - before.abs();
    if (d >= trendCents) return TunerTrend.wrongWay;
    if (d <= -trendCents) return TunerTrend.closer;
    return TunerTrend.none;
  }

  /// Within [harmonicCents] of an octave (either way), a twelfth or two
  /// octaves: where a pitch detector slips to on a plucked string.
  static bool _harmonicOf(double cents) {
    for (final k in const [1200.0, -1200.0, 1902.0, -1902.0, 2400.0]) {
      if ((cents - k).abs() < harmonicCents) return true;
    }
    return false;
  }

  static double _median(List<(Duration, double)> frames) {
    final sorted = [for (final e in frames) e.$2]..sort();
    return sorted[sorted.length ~/ 2];
  }

  static double _hz(double centsFromA4) => 440 * math.pow(2, centsFromA4 / 1200).toDouble();

  void _clear() {
    _levels.clear();
    _start = null;
    _peak = 0;
    _accepted.clear();
    _noteFrames = 0;
    _noteLast = null;
    _pitch = null;
    _lastAccepted = null;
    _history.clear();
    _stray.clear();
    _withinTrend = TunerTrend.none;
    _withinSpoke = false;
    _withinNoneSince = null;
    _settled = null;
    _inSince = null;
    _inTune = false;
    _string = null;
    _previous = null;
  }
}
