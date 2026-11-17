// Replays a recorded tuner session (lib/services/tuner_recording_io.dart)
// through the tuner's own pipeline: the WAV through string_tuner's
// PitchTracker, every frame into TunerModel, with the strings picked and the
// tuning changed when the CSV says they were. So a session from the phone can
// be studied, and the model's settings tried on it, at the desk.
//
//   dart run tool/replay_tuner_session.dart <session>.wav
//       a timeline: each note (onset, settled pitch, what the screen said),
//       every mark with what was on screen around it, and a check that the
//       replay matches what the phone showed
//   dart run tool/replay_tuner_session.dart <session>.wav --set attack=150 --set window=600
//       the same with other settings (ms for attack, window, settleAfter,
//       trendAfter; cents for outlierCents, trendCents; minClarity)
//   dart run tool/replay_tuner_session.dart <session>.wav --frames 12.0-14.5
//       every frame between two times (seconds), recorded and replayed
//
// Pull sessions off a device with scripts/pull_tuner_sessions.sh.
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:string_tuner/string_tuner.dart';
import 'package:violin_practice_companion/services/tuner_advice.dart';
import 'package:violin_practice_companion/services/tuner_input_base.dart';
import 'package:violin_practice_companion/services/tuner_model.dart';

void main(List<String> args) {
  if (args.isEmpty || !args.first.endsWith('.wav')) {
    stderr.writeln('usage: dart run tool/replay_tuner_session.dart <session>.wav '
        '[--set name=value]... [--frames from-to]');
    exit(64);
  }
  final wavPath = args.first;
  final csvPath = '${wavPath.substring(0, wavPath.length - 4)}.csv';
  final sets = <String, double>{};
  (double, double)? frames;
  for (var i = 1; i < args.length; i++) {
    if (args[i] == '--set' && i + 1 < args.length) {
      final kv = args[++i].split('=');
      sets[kv[0]] = double.parse(kv[1]);
    } else if (args[i] == '--frames' && i + 1 < args.length) {
      final r = args[++i].split('-').map(double.parse).toList();
      frames = (r[0], r[1]);
    }
  }

  final (rate, samples) = _readWav(File(wavPath).readAsBytesSync());
  final csv = File(csvPath).readAsLinesSync();
  final header = _header(csv.first);
  final recorded = <_Row>[];
  final events = <(double, String)>[];
  for (final line in csv.skip(2)) {
    final f = _split(line);
    final t = double.parse(f[0]);
    if (f[4].startsWith('event:')) {
      events.add((t, f[4].substring(6)));
    } else {
      recorded.add(_Row(t, f[4], f[7].isEmpty ? null : double.parse(f[7]), f[11]));
    }
  }

  var tuning = _tuning(header['instrument']!, double.parse(header['a4']!));
  Duration ms(String k, int def) => Duration(milliseconds: (sets[k] ?? def).round());
  TunerModel make(InstrumentTuning t) => TunerModel(t,
      minClarity: sets['minClarity'] ?? 0.85,
      attack: ms('attack', 100),
      window: ms('window', 400),
      settleAfter: ms('settleAfter', 900),
      trendAfter: ms('trendAfter', 600),
      outlierCents: sets['outlierCents'] ?? 60,
      trendCents: sets['trendCents'] ?? 4);
  var model = make(tuning);
  final pin = header['pinned'] ?? '';
  if (pin.isNotEmpty) model.pinned = pin;
  final fine = header['instrument'] != 'Mandolin';

  final range = tuning.detectionRange;
  final tracker = PitchTracker(
      YinDetector(sampleRate: rate.toDouble(), minHz: range.minHz, maxHz: range.maxHz),
      frameSize: 2048,
      hopSize: 512);
  final replayed = <_Row>[];
  var ev = 0;
  for (final r in tracker.addSamples(samples)) {
    final t = r.endSample / rate;
    while (ev < events.length && events[ev].$1 <= t) {
      final e = events[ev++].$2;
      if (e.startsWith('picked ') && model.pinned != null) {
        // 'picked A4 inside': the same name again is the pair's other string.
        final name = e.substring(7).split(' ').first;
        if (name == model.pinned && e.split(' ').length > 2) {
          model.newString();
        } else {
          model.pinned = name;
        }
      }
      if (e == 'sense') model.pinned = null;
      if (e.startsWith('choose ')) model.pinned = e.substring(7);
      if (e.startsWith('tuning ')) {
        final w = e.split(' ');
        tuning = _tuning(w[1], double.parse(w[2].split('=')[1]));
        model.tuning = tuning;
      }
    }
    model.add(TunerFrame(Duration(microseconds: (t * 1e6).round()), r.pitch));
    final x = model.reading;
    replayed.add(_Row(t, model.lastDecision.name, x?.cents,
        _status(x, fine, hearing: model.listening), onset: model.lastOnset, live: x?.live ?? false, trend: x?.trend));
  }

  print('${header['instrument']} a4=${header['a4']} pinned=${pin.isEmpty ? 'none (Sense)' : pin} '
      'build=${header['build']}  ${(samples.length / rate).toStringAsFixed(1)} s, '
      '${replayed.length} frames${sets.isEmpty ? '' : '  settings: $sets'}');

  if (frames != null) {
    print('     t   decision(rec/replay)  cents(rec/replay)  status');
    for (var i = 0; i < replayed.length; i++) {
      final p = replayed[i];
      if (p.t < frames.$1 || p.t > frames.$2) continue;
      final q = i < recorded.length ? recorded[i] : null;
      print('${p.t.toStringAsFixed(3).padLeft(7)}  ${(q?.decision ?? '').padRight(8)} '
          '${p.decision.padRight(8)}${p.onset ? '*' : ' '} ${_c(q?.cents)} ${_c(p.cents)}  ${p.status}');
    }
    return;
  }

  // Notes: from each onset, what the screen settled on.
  print('\nnotes (* = live when the next began)');
  var start = -1;
  void note(int end) {
    if (start < 0) return;
    final last = replayed.sublist(start, end).lastWhere((r) => r.cents != null,
        orElse: () => replayed[start]);
    final accepted = replayed.sublist(start, end).where((r) => r.decision == 'accepted').length;
    final rejected = <String, int>{};
    for (final r in replayed.sublist(start, end)) {
      if (r.decision != 'accepted' && r.decision != 'silent') {
        rejected[r.decision] = (rejected[r.decision] ?? 0) + 1;
      }
    }
    print('  ${replayed[start].t.toStringAsFixed(2).padLeft(6)}s  '
        '${((replayed[end - 1].t - replayed[start].t)).toStringAsFixed(1)}s  '
        'shows ${_c(last.cents)}  ${last.trend?.name ?? ''}  "${last.status}"  '
        '[$accepted accepted; ${rejected.entries.map((e) => '${e.key} ${e.value}').join(', ')}]');
  }

  for (var i = 0; i < replayed.length; i++) {
    if (replayed[i].onset) {
      note(i);
      start = i;
    }
  }
  note(replayed.length);

  print('\nwhat the screen said');
  String? said;
  for (final r in replayed) {
    if (r.status != said) {
      print('  ${r.t.toStringAsFixed(2).padLeft(6)}s  ${r.status.isEmpty ? '(nothing)' : r.status}');
      said = r.status;
    }
  }

  if (events.isNotEmpty) {
    print('\nevents');
    for (final (t, e) in events) {
      final around = replayed.where((r) => (r.t - t).abs() < 1.5).toList();
      final cents = around.map((r) => r.cents).whereType<double>().toList();
      print('  ${t.toStringAsFixed(2).padLeft(6)}s  $e'
          '${e == 'mark' && cents.isNotEmpty ? '   ±1.5 s: ${cents.reduce((a, b) => a < b ? a : b).toStringAsFixed(1)}'
              '..${cents.reduce((a, b) => a > b ? a : b).toStringAsFixed(1)}¢, '
              'said ${{for (final r in around) r.status}.map((s) => '"$s"').join(', ')}' : ''}');
    }
  }

  if (sets.isEmpty) {
    var same = 0;
    final n = recorded.length < replayed.length ? recorded.length : replayed.length;
    for (var i = 0; i < n; i++) {
      final a = recorded[i], b = replayed[i];
      if (a.decision == b.decision && a.status == b.status) same++;
    }
    print('\nreplay matches the phone on $same of $n frames'
        '${same == n ? '' : ' (a different build, or audio dropped on the phone)'}');
  }
}

class _Row {
  _Row(this.t, this.decision, this.cents, this.status,
      {this.onset = false, this.live = false, this.trend});
  final double t;
  final String decision, status;
  final double? cents;
  final bool onset, live;
  final TunerTrend? trend;
}

String _c(double? c) => c == null ? '      ' : '${c >= 0 ? '+' : ''}${c.toStringAsFixed(1)}'.padLeft(6);

InstrumentTuning _tuning(String name, double a4) =>
    name == 'Mandolin' ? InstrumentTuning.mandolin(a4: a4) : InstrumentTuning.violin(a4: a4);

Map<String, String> _header(String line) => {
      for (final w in line.substring(2).split(' '))
        if (w.contains('=')) w.substring(0, w.indexOf('=')): w.substring(w.indexOf('=') + 1),
    };

List<String> _split(String line) {
  final out = <String>[];
  final b = StringBuffer();
  var q = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (q) {
      if (c == '"' && i + 1 < line.length && line[i + 1] == '"') {
        b.write('"');
        i++;
      } else if (c == '"') {
        q = false;
      } else {
        b.write(c);
      }
    } else if (c == '"') {
      q = true;
    } else if (c == ',') {
      out.add('$b');
      b.clear();
    } else {
      b.write(c);
    }
  }
  out.add('$b');
  return out;
}

(int, Float32List) _readWav(Uint8List bytes) {
  final d = ByteData.sublistView(bytes);
  var at = 12, rate = 48000;
  while (at + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(at, at + 4));
    final size = d.getUint32(at + 4, Endian.little);
    if (id == 'fmt ') rate = d.getUint32(at + 12, Endian.little);
    if (id == 'data') {
      final end = (at + 8 + size).clamp(0, bytes.length);
      return (rate, pcm16ToFloat32(Uint8List.sublistView(bytes, at + 8, end)));
    }
    at += 8 + size;
  }
  throw const FormatException('no data chunk');
}

String _status(TunerReading? r, bool fineTuners, {bool hearing = false}) =>
    tunerStatus(r, listening: true, playing: false, fineTuners: fineTuners, hearing: hearing);
