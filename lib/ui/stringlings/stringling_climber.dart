import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../splash/stringlings_art.g.dart';

/// One string's rung on the ladder.
class ClimberRung {
  const ClimberRung({required this.letter, required this.color});

  /// `G`, `D`, `A`, `E`.
  final String letter;
  final Color color;
}

/// The tuner's picture: the strings' fingering rules stacked as a ladder,
/// lowest at the bottom, and a stringling doing a chin-up on the string being
/// tuned. Flat, it hangs below its rule; sharp, it is shoved up over it; in
/// tune, it rests on the rule and grins. Its face goes from joy through worry
/// and wincing to agony as the pitch drifts, on the scale in
/// [StringlingFace.pain] (cues people read as pain: brows that lift and then
/// knot, eyes that squeeze shut, a mouth that wobbles and then grits).
///
/// Changing [target] makes it climb there, one rung at a time, hand over
/// hand. [cents] null is idle: resting, blinking, listening.
///
/// With [fineTuners], a turning arrow just above the string's rule shows
/// which way to turn its fine tuner, on the screw head as the player sees it
/// from behind the violin (flattened, the far side up): clockwise raises the
/// pitch, so flat shows clockwise and sharp anti-clockwise. Hidden when in tune, idle or
/// climbing.
///
/// With [onPick], each rung is a tap target (and a button to screen readers)
/// for picking that string. Nothing marks the picked one on screen: the
/// stringling hanging there does.
///
/// It celebrates (a hop, a burst, sparkles) only when it is brought back in
/// tune after being really out, for [CelebrationClock.length] seconds: not
/// when the tuner opens, nor after climbing to an in-tune string.
///
/// Ported from the approved design prototype (the "Stringling Tuner"
/// artifact). The body is the icon's stringling (scripts/app_icon/
/// stringlings_icon.mjs): same ink, eyes and curled fingers.
class StringlingClimber extends StatefulWidget {
  const StringlingClimber({
    super.key,
    required this.rungs,
    required this.target,
    required this.cents,
    this.doubled = false,
    this.fineTuners = false,
    this.falls = 0,
    this.stretches = 0,
    this.picked,
    this.onPick,
    this.party = false,
  });

  final List<ClimberRung> rungs;
  final int target;
  final double? cents;

  /// Draw each rung as a pair of thin rules, for a mandolin's courses.
  final bool doubled;

  /// Show the fine-tuner arrow (violin; a mandolin's tuners turn opposite
  /// ways on the two sides of the head, so one arrow would be wrong).
  final bool fineTuners;

  /// Bumped (with [target] one rung lower) to make it FALL there instead of
  /// climbing: it lets go, drops, catches the lower string with one hand,
  /// swings, and gets the other hand back on. The squirm slider's easter egg.
  final int falls;

  /// Bumped (with [target] one rung higher) for the sharp end's easter egg
  /// instead of a climb: pulled up from above at full stretch, one hand
  /// lets go and its arm recoils up over its head past the next string,
  /// flaps about up there, grabs it, and it pulls itself up.
  final int stretches;

  /// The rung the player picked (selected, to screen readers); null when it
  /// follows what is played.
  final int? picked;

  /// Called with a rung's index when it is tapped.
  final ValueChanged<int>? onPick;

  /// The Playful skin's party: friends in cone hats march in from both
  /// edges along the same string to dance and toot for an earned
  /// celebration, wave and walk off when it ends, and scurry off, worried,
  /// if the string goes out of tune first.
  final bool party;

  /// The resting stringling on [rung] at [cents], in a box of [size], from
  /// the top of its head to the bottom of its feet and side to side: for
  /// tests that check it stays in view and clear of the corner pills.
  @visibleForTesting
  static Rect bodyAt(Size size, int n, int rung, double cents) {
    final l = _Layout(size, n);
    final cy = l.rungY(rung) - l.ry * 0.3 + l.offset(cents);
    return Rect.fromLTRB(l.cx0 - l.rx, cy - l.ry, l.cx0 + l.rx, cy + l.ry * 1.05);
  }

  @override
  State<StringlingClimber> createState() => _StringlingClimberState();
}

class _Climb {
  _Climb(this.from, this.to, this.lead, {this.fall = false, this.stretch = false});
  final int from, to;
  final bool lead; // which hand reaches first (or, falling, catches; or, stretching, flings)
  final bool fall, stretch;
  double t = 0;

  double get seconds => fall ? _fallTime : stretch ? _stretchTime : 0.62;
}

/// When to celebrate, and for how long. A celebration is earned: it starts
/// on landing in tune only after the pitch has really been out of tune
/// (past [armCents] for [armAfter] seconds, while not climbing), so never on
/// opening the tuner, nor on climbing to a string that is already in tune.
/// It lasts [length] seconds, fading over the last [fadeOut].
class CelebrationClock {
  static const length = 3.0, fadeOut = 0.6, armAfter = 0.33, armCents = 6.0;

  /// Out of tune long enough that the next landing in tune celebrates.
  bool armed = false;

  /// Seconds into the celebration; null when there is none (out of tune,
  /// or in tune without having earned one). Keeps counting past [length]
  /// while it stays in tune.
  double? since;

  double _out = 0;
  bool _wasInTune = false;

  /// [steady] is false while climbing; [cents] null is idle.
  void update(double dt, {required double? cents, required bool steady, required bool inTune}) {
    if (steady && cents != null && cents.abs() > armCents) {
      _out += dt;
      if (_out > armAfter) armed = true;
    } else {
      _out = 0;
    }
    if (!inTune) {
      since = null;
    } else if (!_wasInTune && armed) {
      since = 0;
      armed = false;
    } else if (since != null) {
      since = since! + dt;
    }
    _wasInTune = inTune;
  }

  /// 1 while celebrating, easing to 0 over the last [fadeOut] seconds.
  double get fade {
    final c = since;
    if (c == null || c >= length) return 0;
    return 1 - _ease((c - (length - fadeOut)) / fadeOut);
  }
}

/// The party: seconds to march in, to walk off at the end, and to scurry
/// off when it goes out of tune; friends on each side, and how far out the
/// nearest stands, in the hero's widths.
const _march = 1.8, _bye = 0.9, _scurry = 0.5, _friends = 2, _spread = 2.6;

/// A fall's timeline, in seconds: panic (one hand off, flailing, legs
/// kicking), the other hand slips, the drop, then a swing on one arm.
const _panic = 0.7, _letGo = 0.1, _drop = 0.38, _fallTime = 1.85;
const _caught = _panic + _letGo + _drop;

/// The sharp end's stretch, in seconds: straining against the pull from
/// above, the arm's recoil when a hand lets go, its flapping about above
/// the next string, the grab, and the pull up. And how far above the next
/// string the recoil flings the hand, in gaps.
const _strain = 1.0, _recoil = 0.2, _flap = 1.4, _grab = 0.18, _pull = 0.8, _overshoot = 0.8;
const _stretchTime = _strain + _recoil + _flap + _grab + _pull;
const _grabbed = _strain + _recoil + _flap + _grab;

/// When the stretch's hand closes on the next string: the screen's cue for
/// a bump in the hand.
const stretchGrab = Duration(milliseconds: 2780); // _grabbed s

class _StringlingClimberState extends State<StringlingClimber>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _repaint = ValueNotifier<int>(0);
  Duration _last = Duration.zero;

  // Animation state, read by the painter.
  double t = 0; // seconds
  double shown = 0; // smoothed cents
  double held = 0; // seconds in tune
  final party = CelebrationClock();

  // The party parade: 0 (off stage) to 1 (in place, dancing); leaving
  // happily when the celebration ended, worried when it went out of tune.
  double pp = 0;
  bool leaving = false, happyExit = false;
  int partyRung = 0;
  int rung = 0;
  _Climb? climb;
  bool _flip = false;
  bool still = false;

  @override
  void initState() {
    super.initState();
    rung = widget.target;
    shown = widget.cents ?? 0;
    _ticker.start();
  }

  @override
  void didUpdateWidget(StringlingClimber old) {
    super.didUpdateWidget(old);
    // With reduced motion it just climbs down, quickly, as for any change.
    if (widget.falls != old.falls && climb == null && !still && widget.target == rung - 1) {
      climb = _Climb(rung, rung - 1, _flip = !_flip, fall: true);
    }
    if (widget.stretches != old.stretches && climb == null && !still && widget.target == rung + 1) {
      climb = _Climb(rung, rung + 1, _flip = !_flip, stretch: true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final dt = math.min(0.05, (elapsed - _last).inMicroseconds / 1e6);
    _last = elapsed;
    t = elapsed.inMicroseconds / 1e6;

    final target = widget.cents ?? 0;
    shown += (target - shown) * (1 - math.exp(-dt * 9));

    final goal = widget.target.clamp(0, widget.rungs.length - 1);
    if (climb == null && rung != goal) {
      climb = _Climb(rung, rung + (goal > rung ? 1 : -1), _flip = !_flip);
    }
    final c = climb;
    if (c != null) {
      c.t += dt / (still && !c.fall && !c.stretch ? 0.18 : c.seconds);
      if (c.t >= 1) {
        rung = c.to;
        climb = null;
      }
    }
    final inTune = climb == null && widget.cents != null && shown.abs() <= 3;
    held = inTune ? held + dt : 0;
    party.update(dt, cents: widget.cents == null ? null : shown, steady: climb == null, inTune: inTune);
    final since = party.since;
    // They always get a dance in, even past the end of the sparkles.
    final on = widget.party &&
        inTune &&
        since != null &&
        since > 0.3 &&
        since < math.max(CelebrationClock.length, 0.3 + _march + 1.2);
    if (on) {
      if (pp <= 0) partyRung = rung;
      pp = still ? 1 : math.min(1.0, pp + dt / _march);
      leaving = false;
    } else if (pp > 0) {
      if (!leaving) happyExit = inTune;
      leaving = true;
      pp = still || !widget.party ? 0 : math.max(0.0, pp - dt / (happyExit ? _bye : _scurry));
    }
    _repaint.value++;
  }

  @override
  Widget build(BuildContext context) {
    final picture = ExcludeSemantics(
      child: CustomPaint(
        painter: _ClimberPainter(this, _repaint),
        size: Size.infinite,
      ),
    );
    final pick = widget.onPick;
    if (pick == null) return picture;
    // A band round each rung, half a gap either side, is its tap target.
    return LayoutBuilder(builder: (context, box) {
      final l = _Layout(box.biggest, widget.rungs.length);
      return Stack(
        children: [
          Positioned.fill(child: picture),
          for (var i = 0; i < widget.rungs.length; i++)
            Positioned(
              left: 0,
              right: 0,
              top: l.rungY(i) + l.thick / 2 - l.gap / 2,
              height: l.gap,
              child: Semantics(
                button: true,
                selected: widget.picked == i,
                label: '${widget.rungs[i].letter} string',
                child: GestureDetector(
                  key: ValueKey('tuner_string_${widget.rungs[i].letter}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => pick(i),
                ),
              ),
            ),
        ],
      );
    });
  }
}

/// Where the rungs and the stringling go in a box of a given size: shared
/// by the painter and the rungs' tap targets, so the two always agree.
///
/// The rules are spaced so that the stringling at its furthest reach stays
/// in the box: a sharp one on the top string keeps its head inside the
/// card's top edge, rising between the two mode pills the screen lays in its
/// top corners; a flat one on the bottom string keeps its feet above the
/// card's bottom edge. In between it may overlap the next string.
class _Layout {
  _Layout(Size size, this.n) : width = size.width {
    final h = size.height;
    var g = n > 1 ? h * 0.5 / (n - 1) : 0.0;
    double radius(double g) => math.max(20.0, math.min(48.0, math.min(width * 0.075, g * 0.42)));
    // The reach scales with the gap, which is what is left after the
    // reach: a few rounds settle it.
    for (var k = 0; k < 6 && n > 1; k++) {
      final r = radius(g) * 0.87;
      g = (h - roof - _headRoom * r - _feetRoom * r - 2 * reach * g) / (n - 1);
    }
    rx = radius(g);
    ry = rx * 0.87;
    // A short card (a phone on its side) can't afford the full reach: keep
    // the rules from bunching, and give the reach what room is left.
    if (n > 1 && g < minGap) {
      g = math.min(minGap, (h - roof - (_headRoom + _feetRoom) * ry) / (n - 1));
      g = math.max(g, 0.0);
    }
    gap = g;
    final spare = h - roof - (_headRoom + _feetRoom) * ry - (n - 1) * gap;
    reachPx = n > 1 ? math.max(0.0, math.min(reach * gap, spare / 2)) : 0.0;
    // The top string itself stays below the corner controls.
    top = math.max(roof + reachPx + _headRoom * ry, cornerRoom);
    bottom = top + (n - 1) * gap;
    thick = math.max(8.0, rx * 0.26);
    x2 = width - 18;
    // Left of centre, so a sharp head on E clears the Choose | Sense switch
    // under the right pill (it touched it at 0.48 on an SE).
    cx0 = x1 + (x2 - x1) * 0.45;
  }

  final int n;
  final double width;
  late final double top, bottom, gap, rx, ry, thick, x2, cx0;

  /// How far the body moves off its rule at ±50 cents, in points.
  late final double reachPx;
  static const x1 = 58.0;

  /// Air above a sharp head at the card's top edge: the head comes up
  /// between the corner pills, so it needs no room for them.
  static const roof = 4.0;

  /// The corner pills and the Choose | Sense switch under the right one
  /// reach this far down; the top string's rule stays below them.
  static const cornerRoom = 100.0;

  /// The stringling's reach at ±50 cents, as a fraction of the gap between
  /// rules. Over half, a flat one hangs down among the string below's.
  static const reach = 0.95;

  /// How soon it gets there: the exponent on how far out of tune it is.
  /// Under 1 it leaves the string quickly (at 0.5: 45% of its reach at
  /// ±10 cents) so a small mistune is plain to see; 1 is a straight line.
  static const soon = 0.5;

  /// Below this the rules bunch up and the reach gives way instead.
  static const minGap = 52.0;

  // The head's top above its rule (the body hangs 0.3 ry above it, plus
  // its own ry), and the feet's bottom below.
  static const _headRoom = 1.38, _feetRoom = 0.95;

  double rungY(int i) => bottom - i * gap;

  /// The body's offset from its rest pose for [cents]: down when flat, up
  /// when sharp, on the [soon] curve.
  double offset(double cents) {
    final a = math.min(1.0, cents.abs() / 50);
    return a == 0 ? 0 : -cents.sign * reachPx * math.pow(a, soon);
  }
}

const _ink = kStringlingsPupil;
const _white = kStringlingsEyeWhite;
const _sweat = Color(0xFF7EC8F2);
const _blush = Color(0xFFF48FB1);
const _gold = Color(0xFFE8B21C);
const _inkSoft = Color(0xFF6A6180);
const _tuned = Color(0xFF2E7D32);
const _coral = Color(0xFFFF8A80);
const _lilac = Color(0xFFB388FF);

/// The in-tune celebration: how many sparkles, how big (over the old 9
/// point star), and how high it hops when it lands (in body heights, about).
const _sparkles = 16, _sparkleSize = 1.9, _hop = 0.6;

double _ease(double x) => x <= 0 ? 0 : x >= 1 ? 1 : x * x * (3 - 2 * x);

class _ClimberPainter extends CustomPainter {
  _ClimberPainter(this.s, Listenable repaint) : super(repaint: repaint);
  final _StringlingClimberState s;

  @override
  void paint(Canvas canvas, Size size) {
    final w = s.widget;
    final n = w.rungs.length;
    if (n == 0) return;
    final l = _Layout(size, n);
    final gap = l.gap, rx = l.rx, ry = l.ry, thick = l.thick;
    double rungY(int i) => l.rungY(i);
    const x1 = _Layout.x1;
    final x2 = l.x2, cx0 = l.cx0;

    final climbing = s.climb != null;
    final fc = s.climb;
    final target = fc != null &&
            ((fc.fall && fc.t * _fallTime < _caught) || (fc.stretch && fc.t * _stretchTime < _grabbed))
        ? fc.from // don't give the fall or the fling away before it lands
        : w.target.clamp(0, n - 1);
    final idle = w.cents == null;
    final inTune = !climbing && !idle && s.shown.abs() <= 3;

    // Rungs and their labels.
    for (var i = 0; i < n; i++) {
      final r = w.rungs[i];
      final active = i == target;
      final glow = active && inTune ? math.min(1.0, s.held * 2.5) : 0.0;
      _rung(canvas, x1, x2, rungY(i), thick, r.color.withValues(alpha: active ? 1 : 0.45),
          w.doubled, glow, r.color);
      final letterSize = math.min(26.0, gap * 0.36);
      _text(canvas, r.letter, Offset(28, rungY(i) + thick / 2),
          TextStyle(color: r.color, fontSize: letterSize, fontWeight: FontWeight.w900),
          center: true);
    }

    // Pose.
    double handL, handR, anchor, p, dir, offset = 0;
    final handDx = rx * 1.12;
    List<Offset>? hands; // set by a fall, which moves the hands apart
    double bodyDx = 0;
    final c = s.climb;
    final sway = s.still ? 0.0 : math.sin(s.t * 1.6) * 2;
    double panic = 0, wave = 0;
    int? openHand; // the stretch's flung hand, open
    if (c != null && c.stretch) {
      final ya = rungY(c.from), yb = rungY(c.to);
      final sharp = l.offset(50); // up
      final sc = c.lead ? 1.0 : -1.0; // the side of the hand that lets go
      var tt = c.t * _stretchTime;
      double phase(double len) {
        final v = (tt / len).clamp(0.0, 1.0);
        tt -= len;
        return v;
      }
      final strain = phase(_strain), rec = phase(_recoil), flap = phase(_flap);
      final grab = phase(_grab), pull = phase(_pull);
      var cy = ya + sharp - ry * 0.3; // sitting sharp, pulled up from above
      var hold = Offset(cx0 - sc * handDx, ya);
      final peak = yb - gap * _overshoot;
      final restX = cx0 + sc * handDx;
      Offset free;
      if (rec == 0) {
        // Full stretch: dragged further up, trembling harder and harder,
        // the fingers of one hand slipping.
        final k = strain * strain;
        cy -= ry * 0.45 * _ease(strain);
        bodyDx = s.still ? 0 : math.sin(s.t * 38) * (1 + 5 * k);
        free = Offset(restX, ya + (strain > 0.8 ? thick * 0.6 * (strain - 0.8) / 0.2 : 0));
        p = 0.8 + 0.2 * strain;
      } else if (flap == 0) {
        // Snap: like a released rubber band the arm recoils up over its
        // head, past the next string; the body jolts up and swings to the
        // hand still holding.
        final k = 1 - math.pow(1 - rec, 3).toDouble();
        cy -= ry * 0.45 + ry * 0.35 * math.sin(rec * math.pi);
        bodyDx = -sc * rx * 0.35 * k;
        free = Offset(restX + sc * rx * 1.6 * math.sin(k * math.pi) * 0.7, ya + (peak - ya) * k);
        wave = 1;
        p = 0.3;
        panic = 1;
      } else if (grab == 0) {
        // Flapping about up there, swinging side to side and bouncing, the
        // swings dying away as the hand comes down on the string.
        final tf = flap * _flap, die = math.exp(-1.8 * tf) * (1 - flap * flap * flap);
        cy -= ry * 0.45;
        bodyDx = -sc * rx * 0.35 * math.exp(-3 * tf) * math.cos(7 * tf);
        final bounce = s.still ? 0.0 : math.max(math.cos(2 * math.pi * 1.8 * tf), -0.35);
        final whip = s.still ? 0.0 : sc * rx * 1.5 * die * math.sin(2 * math.pi * 2.3 * tf + 0.6);
        free = Offset(restX + whip, yb + (peak - yb) * die * bounce - ry * 0.15 * (1 - flap));
        wave = die;
        p = 0.3;
        panic = flap < 0.5 ? 1 : 0;
      } else if (pull == 0) {
        // The grab.
        cy -= ry * 0.45;
        free = Offset(restX, yb - ry * 0.15 * (1 - _ease(grab)));
        p = 0.4;
      } else {
        // Hand over hand up to the higher string, the other hand following.
        final k = _ease(pull);
        cy = ya + sharp - ry * 0.75 + ((yb + sharp - ry * 0.3) - (ya + sharp - ry * 0.75)) * k;
        free = Offset(restX, yb);
        hold = Offset(cx0 - sc * handDx, ya + (yb - ya) * _ease((pull - 0.45) / 0.5));
        p = 0.6 + 0.35 * k;
      }
      openHand = rec > 0 && grab == 0 ? (sc > 0 ? 1 : 0) : null;
      hands = sc > 0 ? [hold, free] : [free, hold];
      anchor = handL = handR = cy + ry * 0.3; // so the body sits at cy
      dir = 1; // looks up, where it is going
    } else if (c != null && c.fall) {
      final ya = rungY(c.from), yb = rungY(c.to);
      final flat = l.offset(s.shown);
      final d = flat - ry * 0.3; // the body's centre, below its hands
      final over = ry * 0.55; // how far the caught arm stretches
      final sc = c.lead ? -1.0 : 1.0; // the side of the hand that holds on
      final secs = c.t * _fallTime;
      // The free arm flails at its own length from the shoulder, out to the
      // side, never back up as high as the rule (it would look like a grip).
      Offset flail(double cy, double bodyDx) {
        final shoulder = Offset(cx0 + sway + bodyDx - sc * rx * 0.8, cy - ry * 0.05);
        final wave = s.still ? 0.0 : math.sin(s.t * 15) * 0.5 + math.sin(s.t * 37) * 0.12;
        final a = -math.pi / 2 - sc * (1.4 + wave);
        return shoulder + Offset(math.cos(a), math.sin(a)) * rx * 1.05 - Offset(0, thick / 2);
      }
      double cy, catchY;
      Offset free;
      if (secs < _panic) {
        // Hanging by one hand: wide eyes, legs going, the other arm waving.
        final f = secs / _panic;
        cy = ya + d;
        catchY = ya;
        bodyDx = sc * handDx * 0.3 * _ease(f * 2);
        free = flail(cy, bodyDx);
      } else if (secs < _panic + _letGo) {
        // The last hand slips off.
        cy = ya + d;
        catchY = ya - ry * 0.25 * (secs - _panic) / _letGo;
        bodyDx = sc * handDx * 0.3;
        free = flail(cy, bodyDx);
      } else if (secs < _caught) {
        final f = (secs - _panic - _letGo) / _drop;
        cy = ya + d + (yb - ya + over) * f * f; // gravity
        catchY = math.min(cy - d - ry * 0.25 * (1 - f), yb);
        bodyDx = sc * handDx * (0.3 + 0.25 * f);
        free = flail(cy, bodyDx);
      } else {
        // Caught by one hand: bounce on the arm and swing, then the other
        // hand reaches the rule and it settles, really flat.
        final s2 = secs - _caught;
        final k = s2 / (_fallTime - _caught);
        final settle = 1 - _ease(k);
        cy = yb + d + over * math.exp(-5 * s2) * math.cos(11 * s2) * settle;
        catchY = yb;
        bodyDx = sc * handDx * 0.55 * settle + math.sin(s2 * 8) * 4 * settle;
        final g = _ease((k - 0.35) / 0.45);
        final rest = Offset(cx0 - sc * handDx, yb);
        free = Offset.lerp(flail(cy, bodyDx), rest, g)!;
      }
      panic = secs < _caught + 0.2 ? 1 : 0;
      final holding = Offset(cx0 + sc * handDx, catchY);
      hands = c.lead ? [holding, free] : [free, holding];
      anchor = handL = handR = cy + ry * 0.3 - flat; // so the body sits at cy
      offset = flat;
      p = math.max(math.min(1.0, s.shown.abs() / 50), 0.9);
      dir = -1; // looks down, where it is going
    } else if (c != null) {
      final ya = rungY(c.from), yb = rungY(c.to);
      final lead = ya + (yb - ya) * _ease(c.t / 0.42);
      final trail = ya + (yb - ya) * _ease((c.t - 0.45) / 0.42);
      anchor = ya + (yb - ya) * _ease((c.t - 0.12) / 0.76);
      handL = c.lead ? lead : trail;
      handR = c.lead ? trail : lead;
      p = 0; // smiling, but working at it (see StringlingFace.effort)
      dir = c.to > c.from ? -1 : 1; // looks where it is going
      offset = math.sin(c.t * math.pi) * ry * 0.25;
    } else {
      anchor = handL = handR = rungY(s.rung);
      if (idle) {
        p = 0;
        dir = 0;
      } else {
        offset = l.offset(s.shown);
        p = math.min(1.0, s.shown.abs() / 50);
        dir = s.shown < 0 ? -1 : 1;
      }
    }
    final cx = cx0 + sway + bodyDx + (c != null && !c.fall && !c.stretch ? math.sin(c.t * math.pi * 2) * 5 : 0);
    // An earned landing in tune: a hop with a few dwindling bounces, then a
    // happy little jig, and it swells a touch, all settling as it ends.
    var hop = 0.0, grow = 1.0;
    final cel = inTune ? s.party.since : null, fade = inTune ? s.party.fade : 0.0;
    if (cel != null && fade > 0) {
      final k = cel;
      grow = 1 + 0.22 * _hop * math.min(1.0, k * 3) * fade;
      if (!s.still) {
        hop = (math.max(0.0, math.sin(k * 7)) * math.exp(-k * 0.6) * 0.55 +
                (math.sin(k * 4.2)).abs() * 0.12 * math.min(1.0, k)) *
            ry *
            _hop *
            fade;
      }
    }
    final bodyY = anchor - ry * 0.3 + offset - hop;
    if (s.pp > 0) _parade(canvas, l, size);
    if (cel != null && !s.still && cel < 0.9) {
      // A gold ring bursting out as it lands.
      final k = cel / 0.9;
      canvas.drawCircle(
          Offset(cx, bodyY),
          rx * (1 + k * 4),
          Paint()
            ..color = _gold.withValues(alpha: (1 - k) * 0.8)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 6 * (1 - k) + 1);
    }
    StringlingFace(
      cx: cx,
      cy: bodyY,
      rx: rx * grow,
      ry: ry * grow,
      thick: thick,
      hands: hands ?? [Offset(cx0 - handDx, handL), Offset(cx0 + handDx, handR)],
      pain: p,
      dir: dir,
      t: s.t,
      held: s.held,
      sparkle: cel != null && cel > 0.25 ? math.min(1.0, (cel - 0.25) / 0.35) * fade : 0,
      effort: c != null && !c.fall && !c.stretch,
      wave: wave,
      openHand: openHand,
      idle: idle && c == null,
      still: s.still,
      panic: panic,
      accent: w.rungs[target].color,
    ).paint(canvas);

    if (w.fineTuners && !climbing && !idle && !inTune) {
      final r = math.max(11.0, math.min(16.0, gap * 0.2));
      _turnArrow(canvas, Offset(x2 - r - 10, rungY(s.rung) - r * _dialTilt - 10), r,
          clockwise: s.shown < 0, t: s.still ? 0 : s.t);
    }

    if (inTune && s.held > 0.2) {
      _text(canvas, 'in tune', Offset(x2 - 4, rungY(target) + thick + 6),
          TextStyle(
              color: _tuned.withValues(alpha: math.min(1.0, (s.held - 0.2) * 3)),
              fontSize: 12,
              fontWeight: FontWeight.w800),
          right: true);
    }
  }

  /// The party friends, behind the hero, and confetti while they party.
  void _parade(Canvas canvas, _Layout l, Size size) {
    final y = l.rungY(s.partyRung), rx = l.rx * 0.55, ry = rx * 0.87, u = rx / 46;
    final still = s.still, t = s.t;
    final worried = s.leaving && !s.happyExit;
    const colors = [_gold, _coral, _sweat, _lilac, Color(0xFF81C784), _blush];
    final ink = Paint()..color = _ink;
    final line = Paint()
      ..color = _ink
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final white = Paint()..color = _white;
    final wStroke = Paint()
      ..color = _white
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(1.6, 3.4 * u);
    for (final side in [-1.0, 1.0]) {
      for (var k = 0; k < _friends; k++) {
        final i = (side > 0 ? 3 : 0) + k;
        final slot = l.cx0 + side * (l.rx * _spread + k * rx * 3.0);
        final edge = side < 0 ? -rx * 2 - k * rx * 2.4 : size.width + rx * 2 + k * rx * 2.4;
        // Marching in eases in, staggered; leaving runs out straight.
        final f = still ? 1.0 : s.leaving ? s.pp : _ease(math.min(1.0, s.pp * 1.15 - k * 0.08));
        final x = edge + (slot - edge) * math.max(0.0, f);
        final marching = !s.leaving && f < 1, dancing = !s.leaving && f >= 1;
        final bob = still
            ? 0.0
            : marching
                ? math.sin(t * 10 + i).abs() * ry * 0.35
                : dancing
                    ? math.sin(t * 6 + i * 1.3).abs() * ry * 0.5
                    : math.sin(t * 18 + i).abs() * ry * 0.25;
        final cy = y - ry * 1.05 - bob;
        final facing = s.leaving ? side : -side; // at the hero, or away
        // Legs, feet on the string.
        line.strokeWidth = math.max(2.5, 6 * u);
        for (final leg in [-1.0, 1.0]) {
          final step = still
              ? 0.0
              : math.sin(t * (worried ? 22 : 12) + leg * math.pi / 2 + i) * rx * 0.35 * (dancing ? 0.4 : 1);
          canvas.drawLine(Offset(x + leg * rx * 0.3, cy + ry * 0.6), Offset(x + leg * rx * 0.3 + step, y - 1), line);
        }
        // Arms up and waving; flung back when scurrying off.
        line.strokeWidth = math.max(3.0, 8 * u);
        for (final arm in [-1.0, 1.0]) {
          final wave = still ? 0.0 : math.sin(t * 8 + i + arm) * 0.5;
          final a = worried ? -math.pi / 2 - facing * 1.9 + arm * 0.25 : -math.pi / 2 - arm * (0.55 + wave);
          final sh = Offset(x + arm * rx * 0.8, cy);
          canvas.drawLine(sh, sh + Offset(math.cos(a), math.sin(a)) * rx * 1.1, line);
        }
        canvas.drawOval(Rect.fromCenter(center: Offset(x, cy), width: 2 * rx, height: 2 * ry), ink);
        // Face.
        final fx = x + facing * rx * 0.12;
        if (worried) {
          for (final e in [-1.0, 1.0]) {
            final ex = fx + e * rx * 0.34;
            canvas.drawOval(
                Rect.fromCenter(center: Offset(ex, cy - ry * 0.22), width: rx * 0.34, height: ry * 0.44), white);
            canvas.drawCircle(Offset(ex + facing * rx * 0.06, cy - ry * 0.22), rx * 0.08, ink);
          }
          final m = Path()..moveTo(fx - rx * 0.25, cy + ry * 0.3);
          for (var j = 1; j <= 4; j++) {
            m.lineTo(fx - rx * 0.25 + j * rx * 0.125, cy + ry * 0.3 + (j.isOdd ? -1 : 1) * ry * 0.07);
          }
          canvas.drawPath(m, wStroke);
          StringlingFace._drop(canvas, x - facing * rx * 0.9, cy - ry * 0.6, 3 * u + 1);
        } else {
          for (final e in [-1.0, 1.0]) {
            canvas.drawArc(Rect.fromCircle(center: Offset(fx + e * rx * 0.34, cy - ry * 0.16), radius: rx * 0.19),
                math.pi * 1.12, math.pi * 0.76, false, wStroke);
          }
          canvas.drawPath(
              Path()
                ..moveTo(fx - rx * 0.3, cy + ry * 0.15)
                ..quadraticBezierTo(fx, cy + ry * 0.6, fx + rx * 0.3, cy + ry * 0.15)
                ..close(),
              white);
        }
        // A striped cone hat with a gold bobble.
        final hw = rx * 0.62, hh = rx * 1.15;
        final tilt = facing * 0.18 + (still ? 0.0 : math.sin(t * 6 + i) * 0.08);
        canvas.save();
        canvas.translate(x, cy - ry * 0.8);
        canvas.rotate(tilt);
        final hat = Path()
          ..moveTo(-hw, 0)
          ..lineTo(0, -hh)
          ..lineTo(hw, 0)
          ..close();
        canvas.drawPath(hat, Paint()..color = colors[i % colors.length]);
        canvas.save();
        canvas.clipPath(hat);
        final stripe = Paint()
          ..color = const Color(0xBFFFFFFF)
          ..strokeWidth = rx * 0.16;
        for (var m = -2; m < 4; m++) {
          canvas.drawLine(Offset(-hw * 1.5, -m * hh * 0.3), Offset(hw * 1.5, -m * hh * 0.3 - hh * 0.35), stripe);
        }
        canvas.restore();
        canvas.drawCircle(Offset(0, -hh), rx * 0.17, Paint()..color = _gold);
        canvas.restore();
        // The front one on each side toots a horn while dancing.
        if (dancing && k == 0) {
          final blow = still ? 1.0 : 0.6 + 0.4 * math.sin(t * 3 + i).abs();
          canvas.drawLine(
              Offset(fx + facing * rx * 0.2, cy + ry * 0.35),
              Offset(fx + facing * rx * (0.2 + 1.1 * blow), cy + ry * 0.4),
              Paint()
                ..color = _coral
                ..strokeWidth = rx * 0.18
                ..strokeCap = StrokeCap.round);
        }
      }
    }
    // Confetti while they party (and as they walk off happy).
    if (!still && !worried) {
      final a = math.min(1.0, s.pp * 1.5);
      for (var i = 0; i < 26; i++) {
        final x = (i * 53.7) % size.width;
        final yy = (t * 60 * (0.6 + (i % 5) * 0.15) + i * 37) % (size.height + 20) - 10;
        canvas.save();
        canvas.translate(x, yy);
        canvas.rotate(t * 3 + i);
        canvas.drawRect(const Rect.fromLTWH(-3, -1.5, 6, 3),
            Paint()..color = colors[i % 5].withValues(alpha: a * 0.85));
        canvas.restore();
      }
    }
  }

  /// How round a fine tuner's screw head looks to the player: the violin is
  /// under the chin and the eye looks down and forward at the tailpiece, so
  /// the head is seen from above at a slant, about 35° above its plane. The
  /// same for every string.
  static const _dialTilt = 0.55;

  /// The fine tuner's screw head as the player sees it, a flattened disc,
  /// with an arrow running round it the way to turn. The far side of the
  /// head is up the screen, so the arrow's sense on screen is its sense seen
  /// from above, which is how "clockwise" on a fine tuner is meant.
  void _turnArrow(Canvas canvas, Offset c, double r, {required bool clockwise, required double t}) {
    final k = _dialTilt;
    Offset at(double a, [double rad = 1]) =>
        c + Offset(math.cos(a) * r * rad, math.sin(a) * r * k * rad);

    // The screw head under the arrow, and its rim.
    final head = Rect.fromCenter(center: c, width: r * 1.3, height: r * 1.3 * k);
    canvas.drawOval(head.shift(Offset(0, r * 0.14)), Paint()..color = const Color(0x332B2340));
    canvas.drawOval(head, Paint()..color = const Color(0xFFD9CDB6));
    canvas.drawOval(
        head,
        Paint()
          ..color = _inkSoft
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2);

    final dir = clockwise ? 1.0 : -1.0;
    const sweep = math.pi * 1.45;
    // Rotating in the disc's own angle is the head turning, seen at a slant.
    final start = -math.pi / 2 + dir * t * 1.8 - dir * sweep / 2;
    const steps = 36;
    final arc = Path();
    for (var i = 0; i <= steps; i++) {
      final p = at(start + dir * sweep * i / steps);
      i == 0 ? arc.moveTo(p.dx, p.dy) : arc.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
        arc,
        Paint()
          ..color = _ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.24
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);
    // Arrowhead at the leading end, along the flattened path.
    final end = start + dir * sweep;
    final tip = at(end);
    final d = Offset(-math.sin(end) * r, math.cos(end) * r * k) * dir;
    final along = d / d.distance;
    final out = Offset(-along.dy, along.dx);
    final h = r * 0.62;
    canvas.drawPath(
        Path()
          ..moveTo(tip.dx + along.dx * h * 0.9, tip.dy + along.dy * h * 0.9)
          ..lineTo(tip.dx + out.dx * h * 0.7, tip.dy + out.dy * h * 0.7)
          ..lineTo(tip.dx - out.dx * h * 0.7, tip.dy - out.dy * h * 0.7)
          ..close(),
        Paint()..color = _ink);
  }

  void _rung(Canvas canvas, double x1, double x2, double y, double thick, Color color,
      bool doubled, double glow, Color glowColor) {
    final paint = Paint()..color = color;
    if (glow > 0) {
      final g = Paint()
        ..color = glowColor.withValues(alpha: 0.6 * glow)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 * glow);
      canvas.drawRRect(
          RRect.fromLTRBR(x1, y, x2, y + thick, Radius.circular(thick / 2)), g);
    }
    if (doubled) {
      final t = thick * 0.42;
      canvas.drawRRect(RRect.fromLTRBR(x1, y, x2, y + t, Radius.circular(t / 2)), paint);
      canvas.drawRRect(
          RRect.fromLTRBR(x1, y + thick - t, x2, y + thick, Radius.circular(t / 2)), paint);
    } else {
      canvas.drawRRect(RRect.fromLTRBR(x1, y, x2, y + thick, Radius.circular(thick / 2)), paint);
    }
  }

  void _text(Canvas canvas, String text, Offset at, TextStyle style,
      {bool center = false, bool above = false, bool right = false}) {
    final tp = TextPainter(
        text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)
      ..layout();
    var o = at;
    if (center) o -= Offset(tp.width / 2, tp.height / 2);
    if (above) o -= Offset(0, tp.height);
    if (right) o -= Offset(tp.width, 0);
    tp.paint(canvas, o);
  }

  @override
  bool shouldRepaint(_ClimberPainter old) => true;
}

/// One stringling hanging from its hands, with a face for [pain] from 0
/// (joy) to 1 (agony). Public so the face scale can be drawn on its own.
///
///  pain   cents   face
///  <0.08  ±3      joy: eyes shut in happy arcs, blush, open grin
///  <0.12  ±6      nearly: open eyes, a smile
///  <0.4   ±20     worried: inner brows lift, the smile flattens and turns
///  <0.62  ±31     wincing: brows knot down, one eye squeezed, a wobbly mouth
///  ≥0.62          gritted teeth; past 0.78 both eyes clamped, tears at 0.86
///                 Sweat from 0.35 (±18), a second drop from 0.65.
class StringlingFace {
  StringlingFace({
    required this.cx,
    required this.cy,
    required this.rx,
    required this.ry,
    required this.thick,
    required this.hands,
    required this.pain,
    required this.dir,
    required this.t,
    this.held = 0,
    this.sparkle = 0,
    this.effort = false,
    this.wave = 0,
    this.openHand,
    this.idle = false,
    this.still = false,
    this.panic = 0,
    required this.accent,
  });

  final double cx, cy, rx, ry, thick, pain, dir, t, held;

  /// The sparkles' opacity, 0 for none: up while celebrating.
  final double sparkle;

  /// Climbing between strings: smiling but working at it, so a gentle
  /// wiggly mouth and a bead of sweat (with [pain] 0's happy eyes; no
  /// brows, which read as cross).
  final bool effort;

  /// A gentle bend running along the arm of [openHand], 0 for none: the
  /// stretch's flung arm flapping about.
  final double wave;

  /// The index into [hands] of a hand that has let go, drawn open.
  final int? openHand;

  /// Over 0.5: the falling face, wide eyes and an open mouth, legs going
  /// hard, in place of [pain]'s.
  final double panic;
  bool get _panicked => panic > 0.5;
  final List<Offset> hands;
  final bool idle, still;
  final Color accent;

  void paint(Canvas canvas) {
    final u = rx / 46;
    final p = pain;
    final shake = still ? 0.0 : math.sin(t * 43) * p * p * 3.2 * u;
    final x = cx + shake;
    final ink = Paint()..color = _ink;
    final stroke = Paint()
      ..color = _ink
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Arms, behind the body, thinning as they stretch.
    for (var i = 0; i < hands.length; i++) {
      final side = i == 0 ? -1.0 : 1.0;
      final h = hands[i];
      final sx = x + side * rx * 0.8, sy = cy - ry * 0.05;
      final length = (Offset(sx, sy) - h).distance;
      stroke.strokeWidth = 9 * u * (rx * 1.6 / math.max(length, 1)).clamp(0.6, 1.0);
      final mx = (sx + h.dx) / 2 + side * 5 * u, my = (sy + h.dy + thick / 2) / 2;
      final ex = h.dx, ey = h.dy + thick / 2;
      if (i == openHand && wave > 0.02 && !still) {
        // A bend travelling along the flapping arm.
        final len = math.max(1.0, (Offset(ex, ey) - Offset(sx, sy)).distance);
        final nx = -(ey - sy) / len, ny = (ex - sx) / len, amp = rx * 0.16 * wave;
        final path = Path();
        for (var j = 0; j <= 24; j++) {
          final q = j / 24, r = 1 - q;
          final w = math.sin(q * math.pi) * math.sin(q * math.pi * 1.5 - t * 11) * amp;
          final px = r * r * sx + 2 * r * q * mx + q * q * ex + nx * w;
          final py = r * r * sy + 2 * r * q * my + q * q * ey + ny * w;
          j == 0 ? path.moveTo(px, py) : path.lineTo(px, py);
        }
        canvas.drawPath(path, stroke);
      } else {
        canvas.drawPath(
            Path()
              ..moveTo(sx, sy)
              ..quadraticBezierTo(mx, my, ex, ey),
            stroke);
      }
    }

    // Feet, kicking harder the more it hurts.
    for (final k in [-1.0, 1.0]) {
      final kick = still
          ? 0.0
          : math.sin(t * (6 + p * 10 + panic * 18) + k * 1.7) * (1.5 + p * 7 + panic * 12) * u;
      // Panicking, the legs splay and scissor out from under the body.
      final splay = rx * (0.36 + panic * 0.2) + (still ? 0.0 : panic * math.sin(t * 24 + k) * 5 * u);
      canvas.drawOval(
          Rect.fromCenter(
              center: Offset(x + k * splay, cy + ry * (0.9 + panic * 0.12) + kick),
              width: rx * 0.44,
              height: ry * 0.3),
          ink);
    }

    // Body.
    canvas.drawOval(Rect.fromCenter(center: Offset(x, cy), width: 2 * rx, height: 2 * ry), ink);

    // Eyes and brows.
    final ey = cy - ry * 0.25, edx = rx * 0.34, ew = rx * 0.2, eh = ry * 0.27, pr = rx * 0.1;
    final white = Paint()..color = _white;
    final wStroke = Paint()
      ..color = _white
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 3.4 * u;
    final blink = idle && !still ? _blink(t) : 1.0;
    for (final side in [-1.0, 1.0]) {
      final ex = x + side * edx;
      if (_panicked) {
        // Wide open, tiny pupils darting.
        final eye = Rect.fromCenter(center: Offset(ex, ey), width: 2.5 * ew, height: 2.7 * eh);
        canvas.drawOval(eye, white);
        final dart = still ? 0.0 : math.sin(t * 9) * ew * 0.35;
        canvas.drawCircle(Offset(ex + dart, ey + eh * 0.15), pr * 0.7, ink);
        // Brows shot up, inner ends highest.
        final bl = ew * 1.25, by = ey - eh * 1.45 - ry * 0.08;
        canvas.drawLine(Offset(ex + side * bl * 0.5, by + bl * 0.12),
            Offset(ex - side * bl * 0.5, by - bl * 0.18), wStroke..strokeWidth = 3.2 * u);
        wStroke.strokeWidth = 3.4 * u;
        continue;
      }
      if (!idle && p < 0.08) {
        canvas.drawArc(
            Rect.fromCircle(center: Offset(ex, ey + eh * 0.35), radius: ew * 0.95),
            math.pi * 1.12, math.pi * 0.76, false, wStroke);
      } else if (p > 0.78 || (p > 0.55 && side == 1)) {
        final w = ew * 0.9, h = eh * 0.6;
        canvas.drawPath(
            Path()
              ..moveTo(ex - side * w, ey - h)
              ..lineTo(ex + side * w * 0.6, ey)
              ..lineTo(ex - side * w, ey + h),
            wStroke);
      } else {
        final open = (p < 0.3 ? 1.0 : math.max(0.45, 1 - (p - 0.3) * 1.5)) * blink;
        if (open > 0.06) {
          final eye = Rect.fromCenter(center: Offset(ex, ey), width: 2 * ew, height: 2 * eh * open);
          canvas.save();
          canvas.clipPath(Path()..addOval(eye));
          canvas.drawOval(eye, white);
          canvas.drawCircle(Offset(ex - side * rx * 0.02, ey - dir * eh * 0.38 + (idle ? eh * 0.3 : 0)), pr, ink);
          canvas.restore();
        } else {
          canvas.drawLine(Offset(ex - ew, ey), Offset(ex + ew, ey), wStroke);
        }
      }
      if (p >= 0.12) {
        // Worry lifts the inner ends; pain knots them down.
        final bl = ew * 1.25, by = ey - eh - ry * 0.12 + (p > 0.55 ? ry * 0.05 : 0);
        final ang = p <= 0.55 ? 0.15 + (p - 0.12) * 1.1 : -(0.35 + (p - 0.55) * 0.9);
        final inner = Offset(ex - side * bl * 0.55, by - math.sin(ang) * bl * 0.5);
        final outer = Offset(ex + side * bl * 0.45, by + math.sin(ang) * bl * 0.5);
        canvas.drawLine(outer, inner, wStroke..strokeWidth = 3.2 * u);
        wStroke.strokeWidth = 3.4 * u;
      }
    }

    // Cheeks, in tune.
    if (!idle && p < 0.08 && !_panicked) {
      final blush = Paint()..color = _blush.withValues(alpha: 0.75);
      for (final side in [-1.0, 1.0]) {
        canvas.drawOval(
            Rect.fromCenter(
                center: Offset(x + side * rx * 0.58, cy + ry * 0.08), width: rx * 0.26, height: ry * 0.16),
            blush);
      }
    }

    // Mouth.
    final mx = x, my = cy + ry * 0.2, mw = rx * 0.32, mh = ry * 0.18;
    wStroke.strokeWidth = 3.2 * u;
    if (_panicked) {
      // An "oh no" O.
      final o = Rect.fromCenter(center: Offset(mx, my + mh * 0.5), width: mw * 0.85, height: mh * 1.9);
      canvas.drawOval(o, white);
      canvas.drawOval(o.deflate(2.2 * u), Paint()..color = const Color(0xFF8E2A3C));
    } else if (effort) {
      // The strain's wiggly mouth, gentler.
      const segs = 6;
      final w = mw * 1.5, amp = mh * 0.3;
      final wob = still ? 0.0 : math.sin(t * 18) * 0.25;
      final path = Path();
      for (var k = 0; k <= segs; k++) {
        final px = mx - w / 2 + w * k / segs;
        final edge = k == 0 || k == segs ? 0.2 : 1.0;
        final py = my + mh * 0.3 + (k.isOdd ? amp : -amp) * (1 + wob) * edge;
        k == 0 ? path.moveTo(px, py) : path.lineTo(px, py);
      }
      canvas.drawPath(path, wStroke);
    } else if (idle) {
      canvas.drawPath(
          Path()
            ..moveTo(mx - mw * 0.55, my)
            ..quadraticBezierTo(mx, my + mh * 0.9, mx + mw * 0.55, my),
          wStroke);
    } else if (p < 0.08) {
      // Wider the longer it has been in tune.
      final g = 1 + 0.25 * math.min(1.0, held * 3);
      final mouth = Path()
        ..moveTo(mx - mw * g, my - mh * 0.2)
        ..quadraticBezierTo(mx, my + mh * 2.3 * g, mx + mw * g, my - mh * 0.2)
        ..close();
      canvas.drawPath(mouth, white);
      canvas.save();
      canvas.clipPath(mouth);
      canvas.drawOval(
          Rect.fromCenter(center: Offset(mx, my + mh * 1.05 * g), width: mw * g, height: mh * g),
          Paint()..color = const Color(0xFFE57373));
      canvas.restore();
    } else if (p < 0.4) {
      final k = 1 - (p - 0.08) / 0.32 * 1.6;
      canvas.drawPath(
          Path()
            ..moveTo(mx - mw * 0.75, my)
            ..quadraticBezierTo(mx, my + k * mh * 1.5, mx + mw * 0.75, my),
          wStroke);
    } else if (p < 0.62) {
      const segs = 6;
      final w = mw * 1.7, amp = mh * (0.25 + (p - 0.4) * 1.2);
      final wob = still ? 0.0 : math.sin(t * 18) * 0.25;
      final path = Path();
      for (var k = 0; k <= segs; k++) {
        final px = mx - w / 2 + w * k / segs;
        final sag = math.sin(math.pi * k / segs) * -mh * 0.4;
        final edge = k == 0 || k == segs ? 0.2 : 1.0;
        final py = my + mh * 0.15 + sag + (k.isOdd ? amp : -amp) * (1 + wob) * edge;
        k == 0 ? path.moveTo(px, py) : path.lineTo(px, py);
      }
      canvas.drawPath(path, wStroke);
    } else {
      final w = mw * 2 * (0.78 + 0.45 * (p - 0.62) / 0.38), h = mh * 1.25;
      final top = my - h / 2 + mh * 0.2;
      canvas.drawRRect(RRect.fromLTRBR(mx - w / 2, top, mx + w / 2, top + h, Radius.circular(h * 0.35)), white);
      final teeth = Paint()
        ..color = _ink
        ..strokeWidth = 1.6 * u;
      canvas.drawLine(Offset(mx - w / 2, my + mh * 0.2), Offset(mx + w / 2, my + mh * 0.2), teeth);
      for (var k = 1; k < 5; k++) {
        final tx = mx - w / 2 + w * k / 5;
        canvas.drawLine(Offset(tx, top), Offset(tx, top + h), teeth);
      }
    }

    // Sweat and tears.
    if (effort && !_panicked) {
      final slide = still ? 0.0 : ((t * 0.8) % 1) * ry * 0.3;
      _drop(canvas, x + rx * 0.84, cy - ry * 0.62 + slide, 3.4 * u);
    }
    if (p > 0.35) {
      final slide = still ? 0.0 : ((t * 0.6) % 1) * ry * 0.35;
      _drop(canvas, x + rx * 0.82, cy - ry * 0.7 + slide, 4.2 * u);
    }
    if (p > 0.65) {
      final slide = still ? 0.0 : ((t * 0.6 + 0.5) % 1) * ry * 0.35;
      _drop(canvas, x - rx * 0.86, cy - ry * 0.55 + slide, 3.6 * u);
    }
    if (p > 0.86 && !_panicked) {
      for (final side in [-1.0, 1.0]) {
        _drop(canvas, x + side * edx, ey + eh * 1.25, 2.8 * u);
      }
    }

    // Fingers curled over the rule, on top of everything.
    final fw = math.max(5.0, rx * 0.13);
    for (var i = 0; i < hands.length; i++) {
      final h = hands[i];
      if (i == openHand) {
        // Let go: a palm and three splayed fingers.
        final c = Offset(h.dx, h.dy + thick / 2);
        canvas.drawCircle(c, fw * 1.3, ink);
        for (final j in [-1, 0, 1]) {
          canvas.save();
          canvas.translate(c.dx, c.dy);
          canvas.rotate(math.pi + j * 0.6);
          canvas.drawRRect(RRect.fromLTRBR(-fw / 2, 0, fw / 2, fw * 2.4, Radius.circular(fw / 2)), ink);
          canvas.restore();
        }
        continue;
      }
      for (final j in [-1, 0, 1]) {
        final fx = h.dx + j * fw * 1.15 - fw / 2;
        canvas.drawRRect(
            RRect.fromLTRBR(fx, h.dy - fw * 0.55, fx + fw, h.dy + thick + 3 * u, Radius.circular(fw / 2)),
            ink);
      }
    }

    // Sparkles once it has settled in tune: a ring of them at golden-angle
    // spacing, twinkling, turning and drifting up and out.
    if (sparkle > 0) {
      final a = sparkle;
      final colors = [_gold, accent, _coral, _sweat, _lilac];
      for (var k = 0; k < _sparkles; k++) {
        final ang = k * 2.399 + 0.3, ring = 1.35 + (k * 0.37) % 1 * 1.4;
        final drift = still ? 0.0 : math.sin(t * 1.3 + k) * 0.15;
        final rise = still ? 0.0 : (t * 0.25 + k * 0.13) % 1 * ry * 0.4;
        final at = Offset(x + math.cos(ang) * rx * ring * (1 + drift),
            cy + math.sin(ang) * ry * ring * 0.95 - rise);
        final tw = still ? 1.0 : 0.55 + 0.45 * math.sin(t * 5 + k * 1.9);
        final size = 9 * u * _sparkleSize * tw * (0.6 + (k * 0.61) % 1 * 0.6);
        _star(canvas, at, size, colors[k % colors.length].withValues(alpha: a),
            still ? 0.0 : t * (k.isOdd ? 1 : -1));
      }
    }
  }

  // Eyes open most of a 4.5 s cycle; a quick blink near its end.
  static double _blink(double t) {
    final d = ((t % 4.5) - 4.2) / 0.16;
    if (d <= 0 || d >= 1) return 1;
    return (2 * d - 1).abs();
  }

  static void _drop(Canvas canvas, double x, double y, double r) {
    final path = Path()
      ..moveTo(x, y - r * 1.8)
      ..cubicTo(x + r * 0.2, y - r * 1.1, x + r, y - r * 0.5, x + r, y)
      ..arcTo(Rect.fromCircle(center: Offset(x, y), radius: r), 0, math.pi, false)
      ..cubicTo(x - r, y - r * 0.5, x - r * 0.2, y - r * 1.1, x, y - r * 1.8);
    canvas.drawPath(path, Paint()..color = _sweat);
    canvas.drawCircle(Offset(x - r * 0.35, y - r * 0.15), r * 0.28,
        Paint()..color = const Color(0xBFFFFFFF));
  }

  static void _star(Canvas canvas, Offset c, double r, Color color, [double turn = 0]) {
    final path = Path();
    for (var k = 0; k < 8; k++) {
      final a = k * math.pi / 4 + turn, rad = k.isOdd ? r * 0.32 : r;
      final pt = c + Offset(math.cos(a) * rad, math.sin(a) * rad);
      k == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }
}
