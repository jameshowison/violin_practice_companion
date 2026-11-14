// Pure Dart, so tool/replay_tuner_session.dart says exactly what the screen does.
import 'tuner_model.dart';

/// The tuner's status line for [r]: which way to turn and, from the
/// model's [TunerReading.trend], whether the last turn went the right way. "Wrong
/// way" is the commonest mistake there is, so it is said first and plainly,
/// with the way to go instead.
String tunerStatus(TunerReading? r,
    {required bool listening, required bool playing, required bool fineTuners}) {
  if (r == null) return listening ? 'Play a string' : '';
  final c = r.cents, a = c.abs();
  if (r.inTune) return playing ? '' : 'In tune!';
  final flat = c < 0, peg = a > 40;
  final way = peg
      ? (flat ? 'the peg up' : 'the peg down')
      : !fineTuners
          ? null // a mandolin's tuners turn opposite ways on the two sides
          : (flat ? 'clockwise' : 'anti-clockwise');
  final tuner = flat ? 'tighten' : 'loosen';
  switch (r.trend) {
    case TunerTrend.wrongWay:
      return way == null ? 'Wrong way! ${_cap(tuner)} it instead' : 'Wrong way! Turn $way instead';
    case TunerTrend.overshot:
      return way == null ? 'Too far! ${_cap(tuner)} it a little' : 'Too far! Back a little, $way';
    case TunerTrend.closer:
      return way == null ? 'Closer! Keep going' : 'Closer! Keep turning $way';
    case TunerTrend.none:
      break;
  }
  if (peg) {
    return flat ? 'Very flat · the peg needs a turn up' : 'Very sharp · the peg needs a turn down';
  }
  if (!fineTuners) return flat ? 'Flat · tighten the tuner' : 'Sharp · loosen the tuner';
  return flat ? 'Flat · turn the fine tuner clockwise' : 'Sharp · turn the fine tuner anti-clockwise';
}

String _cap(String s) => s[0].toUpperCase() + s.substring(1);
