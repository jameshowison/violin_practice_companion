// Pure Dart, so tool/replay_tuner_session.dart says exactly what the screen does.
import 'tuner_model.dart';
import 'unison_meter.dart';

/// The tuner's status line for [r]: which way to turn and, from the
/// model's [TunerReading.trend], whether the last turn went the right way. "Wrong
/// way" is the commonest mistake there is, so it is said first and plainly,
/// with the way to go instead.
///
/// While [hearing] (a note just begun, [TunerModel.listening]) it says so
/// instead: advice taken from a pluck's first moments would change under the
/// player's hands.
String tunerStatus(TunerReading? r,
    {required bool listening, required bool playing, required bool fineTuners, bool hearing = false}) {
  if (listening && hearing) return 'Listening…';
  if (r == null) return listening ? 'Play a string' : '';
  final c = r.cents, a = c.abs();
  if (r.inTune) return playing ? '' : 'In tune!';
  final flat = c < 0;
  if (!fineTuners) return _mandolin(r, flat: flat, very: a > 40);
  final peg = a > 40;
  final way = peg
      ? (flat ? 'the peg up' : 'the peg down')
      : (flat ? 'clockwise' : 'anti-clockwise');
  final half = fineTunerHalfTurn(c);
  switch (r.trend) {
    case TunerTrend.wrongWay:
      return half ? 'Wrong way! Half a turn $way instead' : 'Wrong way! Turn $way instead';
    case TunerTrend.overshot:
      return half ? 'Too far! Half a turn back, $way' : 'Too far! Back a little, $way';
    case TunerTrend.closer:
      return half ? 'Closer! Another half turn $way' : 'Closer! Keep turning $way';
    case TunerTrend.none:
      break;
  }
  if (peg) {
    return flat ? 'Very flat · the peg needs a turn up' : 'Very sharp · the peg needs a turn down';
  }
  if (half) return flat ? 'Flat · half a turn clockwise, no more' : 'Sharp · half a turn anti-clockwise, no more';
  return flat ? 'Flat · turn the fine tuner clockwise' : 'Sharp · turn the fine tuner anti-clockwise';
}

/// Close enough that a fine tuner wants only half a turn before listening
/// again. A teacher's rule ("half turn only") for a student who kept turning
/// past the note: the screen says it, and the arrow turns half a turn, slowly,
/// and stops.
const fineTunerHalfTurnCents = 15.0;

bool fineTunerHalfTurn(double cents) => cents.abs() <= fineTunerHalfTurnCents;

/// A mandolin's tuners stick out of the headstock's two edges, G and D on the
/// side nearer the player's eye, A and E on the far side, and their gears
/// run opposite ways: seen end-on, clockwise loosens on both. So the advice
/// is how the top of the button rolls, as the player looks down at it: to
/// tighten, toward the headstock end on G and D, toward the body on A and E.
/// It holds for a left-handed (mirror-image) mandolin too. There are no pegs,
/// so a long way out is the same roll, said louder.
String _mandolin(TunerReading r, {required bool flat, required bool very}) {
  final towards = 'toward ${mandolinRollsToEnd(r.string.name[0], tighten: flat) ? 'the headstock end' : 'the body'}';
  switch (r.trend) {
    case TunerTrend.wrongWay:
      return 'Wrong way! Roll the top $towards';
    case TunerTrend.overshot:
      return 'Too far! Roll it back a little, $towards';
    case TunerTrend.closer:
      return 'Closer! Keep rolling $towards';
    case TunerTrend.none:
      break;
  }
  final what = very ? (flat ? 'Very flat' : 'Very sharp') : (flat ? 'Flat' : 'Sharp');
  return '$what · roll the top $towards';
}

/// Whether, to [tighten] (or loosen) a string of [course] (`'G'`, `'D'`,
/// `'A'` or `'E'`), the top of its tuner button rolls toward the headstock's
/// end (true) or toward the body (false). Tested by hand on a mandolin.
bool mandolinRollsToEnd(String course, {required bool tighten}) =>
    (course == 'G' || course == 'D') == tighten;

/// Before a pluck, with both strings of a mandolin course to be played together.
const unisonPrompt = 'Play both strings together';

/// What to say once a pluck of both strings of a course has been judged
/// ([UnisonMeter]): [v] is null when it rang too briefly to say, [r] is the
/// course's reading, the pair's pitch together. Only "together, and in tune"
/// passes; [unisonPassed] says whether it did, and anything else sends the
/// player back to tuning each string.
String unisonStatus(UnisonVerdict? v, TunerReading? r) {
  if (v == null) return 'Let both strings ring a little longer';
  if (!v.together) return 'They beat, about ${v.cents.round()}¢ apart · tune each string again';
  if (r != null && !r.inTune) return 'Together, but both ${r.cents < 0 ? 'flat' : 'sharp'} · tune each string again';
  return 'Together! Both strings in tune';
}

bool unisonPassed(UnisonVerdict? v, TunerReading? r) => v != null && v.together && (r == null || r.inTune);
