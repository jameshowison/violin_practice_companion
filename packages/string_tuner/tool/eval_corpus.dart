// Scores the detector against recordings labelled by a reference tuner.
//
//   dart run tool/eval_corpus.dart <dir>                 # table of every take
//   dart run tool/eval_corpus.dart <dir> --csv out.csv   # the same, as CSV
//   dart run tool/eval_corpus.dart <dir> --frames <file> # every reading of one take
//
// <dir> holds the audio and a takes.csv:
//
//   file,instrument,string,ref_cents,ref_a4,note
//   violin_G_0.m4a,violin,G,0,440,
//   violin_G_m25.m4a,violin,G,-25,440,peg
//   session_violin_01.m4a,violin,,,440,free tuning
//
// ref_cents is what the reference tuner showed, which is assumed to be
// equal-tempered from ref_a4 (nearly every tuner's default). A take with no
// string is a free session: it gets a timeline of the strings followed
// instead of a score. Audio other than WAV is converted with macOS's
// afconvert into a temporary directory.
//
// Optional start_s and end_s columns cut each take out of a longer recording,
// as written by the Tuning Takes page: one recording per instrument, starting
// with three short 3 kHz beeps. Times count from the first of those beeps,
// which this script finds in the audio.
//
// Columns:
//   err¢    median reading minus what the tuner said, in cents
//   iqr¢    spread of the settled readings (interquartile range), in cents
//   voiced  share of readings clear enough to use (clarity >= --clarity)
//   gross   share of usable readings more than 300 cents out, of which
//   oct     share near a whole octave out
//   lock    ms from the first usable reading to five in a row within 3 cents
//           of the take's median
//   string  string the follower settled on (! if not the labelled one)
//   shows¢  what this package's tuner would display: the median against its
//           own target (pure fifths for violin), so a G the tuner calls 0
//           shows about +3.9
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:string_tuner/string_tuner.dart';

const _hop = 512, _frame = 2048;

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first.startsWith('-')) {
    stderr.writeln('usage: dart run tool/eval_corpus.dart <dir> [--csv out.csv] '
        '[--frames <file>] [--clarity 0.85]');
    exit(64);
  }
  final dir = Directory(args.first);
  String? opt(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final minClarity = double.parse(opt('--clarity') ?? '0.85');
  final takes = _readTakes(File('${dir.path}/takes.csv'));
  final tmp = Directory.systemTemp.createTempSync('string_tuner_eval');
  try {
    final framesFor = opt('--frames');
    if (framesFor != null) {
      final take = takes.firstWhere((t) => t.file == framesFor,
          orElse: () => throw ArgumentError('$framesFor is not in takes.csv'));
      _dumpFrames(take, _audioFor(take, dir, tmp), minClarity);
      return;
    }
    final rows = <List<String>>[];
    final sessions = <String>[];
    for (final take in takes) {
      final audio = _audioFor(take, dir, tmp);
      if (take.string == null) {
        sessions.add(_session(take, audio, minClarity));
      } else {
        rows.add(_score(take, audio, minClarity));
      }
    }
    const header = ['file', 'err¢', 'iqr¢', 'voiced', 'gross', 'oct', 'lock', 'string', 'shows¢', 'note'];
    _printTable(header, rows);
    for (final s in sessions) {
      stdout.writeln('\n$s');
    }
    final csv = opt('--csv');
    if (csv != null) {
      File(csv).writeAsStringSync(
          '${[header, ...rows].map((r) => r.map(_csvCell).join(',')).join('\n')}\n');
      stdout.writeln('\nwrote $csv');
    }
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

// ---------- takes.csv ----------

class _Take {
  _Take(this.file, this.instrument, this.string, this.refCents, this.refA4, this.note,
      this.start, this.end);
  final String file, instrument, note;
  final String? string; // G, D, A, E; null for a free session
  final double refCents, refA4;
  final double? start, end; // seconds after the sync beeps

  /// The file, plus where in it for a take cut from a longer recording.
  String get label => start == null
      ? file
      : '${file.replaceFirst(RegExp(r'\.\w+$'), '')} @${start!.toStringAsFixed(1)}s';

  InstrumentTuning get tuning => switch (instrument.toLowerCase()) {
        'violin' => InstrumentTuning.violin(a4: refA4),
        'viola' => InstrumentTuning.viola(a4: refA4),
        'cello' => InstrumentTuning.cello(a4: refA4),
        'mandolin' => InstrumentTuning.mandolin(a4: refA4),
        _ => throw FormatException('unknown instrument "$instrument" for $file'),
      };
}

List<_Take> _readTakes(File f) {
  if (!f.existsSync()) throw FileSystemException('no takes.csv', f.path);
  final lines = f.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
  final head = _splitCsv(lines.first).map((h) => h.trim().toLowerCase()).toList();
  int col(String name) {
    final i = head.indexOf(name);
    if (i < 0) throw FormatException('takes.csv has no "$name" column');
    return i;
  }

  final cFile = col('file'), cInst = col('instrument'), cStr = col('string'),
      cRef = col('ref_cents'), cA4 = col('ref_a4');
  final cNote = head.indexOf('note');
  final cStart = head.indexOf('start_s'), cEnd = head.indexOf('end_s');
  return [
    for (final line in lines.skip(1))
      () {
        final c = _splitCsv(line);
        String at(int i) => i >= 0 && i < c.length ? c[i].trim() : '';
        // "0/+10" (a mandolin pair with one string off) scores against the first.
        final ref = at(cRef).split('/').first;
        return _Take(
          at(cFile),
          at(cInst),
          at(cStr).isEmpty ? null : at(cStr).toUpperCase(),
          ref.isEmpty ? 0 : double.parse(ref.replaceAll('+', '')),
          at(cA4).isEmpty ? 440 : double.parse(at(cA4)),
          at(cNote),
          at(cStart).isEmpty ? null : double.parse(at(cStart)),
          at(cEnd).isEmpty ? null : double.parse(at(cEnd)),
        );
      }()
  ];
}

List<String> _splitCsv(String line) {
  final out = <String>[];
  final b = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      if (quoted && i + 1 < line.length && line[i + 1] == '"') {
        b.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (ch == ',' && !quoted) {
      out.add(b.toString());
      b.clear();
    } else {
      b.write(ch);
    }
  }
  out.add(b.toString());
  return out;
}

String _csvCell(String s) =>
    s.contains(RegExp(r'[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;

// ---------- audio ----------

final _files = <String, _Audio>{};
final _syncs = <String, double>{};

/// The take's audio: the whole file, or its start_s..end_s slice.
_Audio _audioFor(_Take take, Directory dir, Directory tmp) {
  final whole = _files.putIfAbsent(take.file, () => _load(dir, take.file, tmp));
  if (take.start == null) return whole;
  final sync = _syncs.putIfAbsent(take.file, () {
    final at = _findSync(whole);
    if (at == null) {
      throw StateError('${take.file}: no sync beeps (three short 3 kHz beeps) found');
    }
    stdout.writeln('${take.file}: sync beeps at ${at.toStringAsFixed(2)} s');
    return at;
  });
  final sr = whole.sampleRate;
  final a = ((sync + take.start!) * sr).round().clamp(0, whole.samples.length);
  final b = take.end == null
      ? whole.samples.length
      : ((sync + take.end!) * sr).round().clamp(a, whole.samples.length);
  return _Audio(Float32List.sublistView(whole.samples, a, b), sr);
}

/// Seconds to the first of three short 3 kHz beeps 0.1–0.25 s apart, or null.
/// Looks for 10 ms blocks whose energy is mostly at 3 kHz (Goertzel), groups
/// them into bursts, and takes the first run of three.
double? _findSync(_Audio a, {double hz = 3000}) {
  final sr = a.sampleRate, n = (sr / 100).round();
  final coeff = 2 * math.cos(2 * math.pi * hz / sr);
  final onsets = <double>[];
  var inBurst = false;
  for (var b = 0; b + n <= a.samples.length; b += n) {
    var s1 = 0.0, s2 = 0.0, ms = 0.0;
    for (var i = b; i < b + n; i++) {
      final x = a.samples[i];
      final s0 = x + coeff * s1 - s2;
      s2 = s1;
      s1 = s0;
      ms += x * x;
    }
    ms /= n;
    final power = s1 * s1 + s2 * s2 - coeff * s1 * s2; // |X|^2
    final amp = 2 * math.sqrt(power) / n;
    final tonal = ms > 1e-7 && (amp * amp / 2) / ms > 0.5;
    if (tonal && !inBurst) onsets.add(b / sr);
    inBurst = tonal;
  }
  for (var i = 0; i + 2 < onsets.length; i++) {
    final g1 = onsets[i + 1] - onsets[i], g2 = onsets[i + 2] - onsets[i + 1];
    if (g1 > 0.1 && g1 < 0.25 && g2 > 0.1 && g2 < 0.25) return onsets[i];
  }
  return null;
}

class _Audio {
  _Audio(this.samples, this.sampleRate);
  final Float32List samples;
  final double sampleRate;
}

_Audio _load(Directory dir, String name, Directory tmp) {
  var path = '${dir.path}/$name';
  if (!File(path).existsSync()) throw FileSystemException('missing audio', path);
  if (!name.toLowerCase().endsWith('.wav')) {
    final out = '${tmp.path}/${name.replaceAll(RegExp(r'[^\w.-]'), '_')}.wav';
    final r = Process.runSync('afconvert', ['-f', 'WAVE', '-d', 'LEI16', path, out]);
    if (r.exitCode != 0) {
      throw ProcessException('afconvert', [path], '${r.stderr}', r.exitCode);
    }
    path = out;
  }
  return _readWav(File(path).readAsBytesSync(), path);
}

/// PCM 16/24/32-bit or float32 WAV, any channel count, mixed to mono.
_Audio _readWav(Uint8List bytes, String path) {
  final v = ByteData.sublistView(bytes);
  String tag(int o) => String.fromCharCodes(bytes.sublist(o, o + 4));
  if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
    throw FormatException('not a WAV file', path);
  }
  int? format, channels, rate, bits;
  ByteData? data;
  var o = 12;
  while (o + 8 <= bytes.length) {
    final id = tag(o), size = v.getUint32(o + 4, Endian.little);
    final body = o + 8;
    if (id == 'fmt ') {
      format = v.getUint16(body, Endian.little);
      channels = v.getUint16(body + 2, Endian.little);
      rate = v.getUint32(body + 4, Endian.little);
      bits = v.getUint16(body + 14, Endian.little);
      if (format == 0xFFFE) format = v.getUint16(body + 24, Endian.little);
    } else if (id == 'data') {
      data = ByteData.sublistView(bytes, body, math.min(bytes.length, body + size));
    }
    o = body + size + (size & 1);
  }
  if (format == null || data == null) throw FormatException('WAV lacks fmt or data', path);
  final step = bits! ~/ 8, frameBytes = step * channels!;
  final n = data.lengthInBytes ~/ frameBytes;
  double sample(int at) => switch ((format, bits)) {
        (1, 16) => data!.getInt16(at, Endian.little) / 32768,
        (1, 24) => (((data!.getUint8(at + 2) << 24) | (data.getUint8(at + 1) << 16) |
                    (data.getUint8(at) << 8)).toSigned(32)) /
            2147483648,
        (1, 32) => data!.getInt32(at, Endian.little) / 2147483648,
        (3, 32) => data!.getFloat32(at, Endian.little),
        _ => throw FormatException('unsupported WAV format $format/$bits-bit', path),
      };
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    var s = 0.0;
    for (var c = 0; c < channels; c++) {
      s += sample(i * frameBytes + c * step);
    }
    out[i] = s / channels;
  }
  return _Audio(out, rate!.toDouble());
}

// ---------- analysis ----------

class _Run {
  _Run(this.times, this.readings);
  final List<double> times; // seconds, end of each frame
  final List<PitchEstimate?> readings;
}

_Run _track(_Take take, _Audio a) {
  final range = take.tuning.detectionRange;
  final tracker = PitchTracker(
    YinDetector(sampleRate: a.sampleRate, minHz: range.minHz, maxHz: range.maxHz),
    frameSize: _frame,
    hopSize: _hop,
  );
  final rs = tracker.addSamples(a.samples);
  return _Run([for (final r in rs) r.endSample / a.sampleRate], [for (final r in rs) r.pitch]);
}

double _median(List<double> xs) {
  final s = [...xs]..sort();
  if (s.isEmpty) return double.nan;
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

double _quantile(List<double> sorted, double q) {
  if (sorted.isEmpty) return double.nan;
  final x = q * (sorted.length - 1);
  final lo = x.floor(), hi = x.ceil();
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (x - lo);
}

String _f(double x, [int digits = 1]) {
  if (x.isNaN) return '–';
  final s = x.toStringAsFixed(digits);
  return RegExp(r'^-0\.0*$').hasMatch(s) ? s.substring(1) : s;
}
String _pct(double x) => x.isNaN ? '–' : '${(100 * x).round()}%';

List<String> _score(_Take take, _Audio a, double minClarity) {
  final tuning = take.tuning;
  final run = _track(take, a);
  final target = tuning.strings.firstWhere(
      (s) => s.name.startsWith(take.string!),
      orElse: () => throw FormatException('${take.file}: no ${take.string} string on ${tuning.name}'));
  // What the reference tuner was pointing at: the equal-tempered note, offset
  // by its reading.
  final expected = midiToHz(target.midi, a4: take.refA4) * math.pow(2, take.refCents / 1200);

  final usable = <int>[
    for (var i = 0; i < run.readings.length; i++)
      if ((run.readings[i]?.clarity ?? 0) >= minClarity) i
  ];
  final voiced = run.readings.isEmpty ? double.nan : usable.length / run.readings.length;
  final cents = [for (final i in usable) centsBetween(run.readings[i]!.hz, expected)];
  final gross = cents.where((c) => c.abs() > 300).toList();
  final octave = gross.where((c) => ((c.abs() - 1200).abs() < 100) || ((c.abs() - 2400).abs() < 100));
  final good = cents.where((c) => c.abs() <= 300).toList();

  // Settled readings: drop the first 0.3 s after sound starts.
  final settled = <double>[];
  if (usable.isNotEmpty) {
    final t0 = run.times[usable.first];
    for (var k = 0; k < usable.length; k++) {
      if (run.times[usable[k]] - t0 >= 0.3 && cents[k].abs() <= 300) settled.add(cents[k]);
    }
  }
  final base = settled.isNotEmpty ? settled : good;
  final med = _median(base);
  final sorted = [...base]..sort();
  final iqr = _quantile(sorted, 0.75) - _quantile(sorted, 0.25);

  // Lock: first run of five usable readings within 3 cents of the median.
  var lockMs = double.nan;
  var streak = 0;
  for (var k = 0; k < usable.length; k++) {
    if ((cents[k] - med).abs() <= 3) {
      if (++streak == 5) {
        lockMs = 1000 * (run.times[usable[k - 4]] - run.times[usable.first]);
        break;
      }
    } else {
      streak = 0;
    }
  }

  // The string follower, fed every usable reading, as the app would.
  final follower = StringFollower(tuning);
  StringReading? last;
  for (final i in usable) {
    last = follower.update(run.readings[i]!.hz);
  }
  final followed = last?.string;
  final medHz = expected * math.pow(2, med / 1200);
  final shows = med.isNaN ? double.nan : centsBetween(medHz, target.hz);

  return [
    take.label,
    _f(med),
    _f(iqr),
    _pct(voiced),
    _pct(cents.isEmpty ? double.nan : gross.length / cents.length),
    _pct(cents.isEmpty ? double.nan : octave.length / cents.length),
    lockMs.isNaN ? '–' : '${lockMs.round()}',
    followed == null ? '–' : '${followed.name}${followed.midi == target.midi ? '' : '!'}',
    _f(shows),
    take.note,
  ];
}

String _session(_Take take, _Audio a, double minClarity) {
  final run = _track(take, a);
  final follower = StringFollower(take.tuning);
  final b = StringBuffer('${take.label} (${take.instrument}, '
      '${(a.samples.length / a.sampleRate).toStringAsFixed(1)} s): strings followed\n');
  String? current;
  double? since;
  final cents = <double>[];
  var changes = 0;
  void flush(double until) {
    if (current == null) return;
    final c = _median(cents);
    b.writeln('  ${_clock(since!)}–${_clock(until)}  $current  '
        'median ${_f(c)}¢ over ${cents.length} readings');
  }

  for (var i = 0; i < run.readings.length; i++) {
    final p = run.readings[i];
    if (p == null || p.clarity < minClarity) continue;
    final r = follower.update(p.hz);
    if (r.string.name != current) {
      flush(run.times[i]);
      if (current != null) changes++;
      current = r.string.name;
      since = run.times[i];
      cents.clear();
    }
    cents.add(r.cents);
  }
  flush(run.times.isEmpty ? 0 : run.times.last);
  b.write('  $changes string changes');
  return b.toString();
}

String _clock(double s) =>
    '${s ~/ 60}:${(s % 60).toStringAsFixed(1).padLeft(4, '0')}';

void _dumpFrames(_Take take, _Audio a, double minClarity) {
  final run = _track(take, a);
  stdout.writeln('t_s,hz,clarity,rms,usable');
  for (var i = 0; i < run.readings.length; i++) {
    final p = run.readings[i];
    stdout.writeln([
      run.times[i].toStringAsFixed(3),
      p == null ? '' : p.hz.toStringAsFixed(3),
      p == null ? '' : p.clarity.toStringAsFixed(3),
      p == null ? '' : p.rms.toStringAsFixed(4),
      p != null && p.clarity >= minClarity ? 1 : 0,
    ].join(','));
  }
}

void _printTable(List<String> header, List<List<String>> rows) {
  final w = [
    for (var c = 0; c < header.length; c++)
      [header[c], ...rows.map((r) => r[c])].map((s) => s.length).reduce(math.max)
  ];
  String line(List<String> r) => [
        for (var c = 0; c < r.length; c++) c == 0 || c == r.length - 1 ? r[c].padRight(w[c]) : r[c].padLeft(w[c])
      ].join('  ').trimRight();
  stdout.writeln(line(header));
  for (final r in rows) {
    stdout.writeln(line(r));
  }
}
