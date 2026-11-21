import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'tuner_model.dart';

/// One listening session, recorded for development: `<name>.wav` (the
/// microphone, mono 16-bit at [sampleRate], exactly what the detector heard)
/// and `<name>.csv` (one row per frame: the pitch estimate, what [TunerModel]
/// did with it, and what the screen said; plus `event:` rows for marks and
/// string changes), in `Documents/tuner_sessions/`.
///
/// A frame's `t` is its end sample over [sampleRate], counted from the
/// microphone's first sample, which is also the WAV's first: so a row's time
/// is its place in the audio.
///
/// Only the newest [keep] sessions are kept, and a session stops recording
/// audio after [maxSeconds] (about 5.6 MB a minute). Nothing leaves the
/// device: the files are pulled over the cable.
class TunerRecording {
  TunerRecording._(this.name, this._wavFile, this._wav, this._csv);

  static const dirName = 'tuner_sessions', keep = 10, maxSeconds = 600;
  static const sampleRate = 48000;

  final String name;
  final File _wavFile;
  final IOSink _wav, _csv;
  int _bytes = 0;
  Duration _at = Duration.zero;
  bool _closed = false;

  static const columns =
      't,hz,clarity,rms,decision,onset,string,cents,live,in_tune,trend,status';

  /// Starts a session under [root] (default: the documents directory), its
  /// first line `# ` and [header]. Null if it can't be written.
  static Future<TunerRecording?> start(
      {required String header, Directory? root, DateTime? now}) async {
    try {
      final docs = root ?? await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/$dirName');
      await dir.create(recursive: true);
      await _prune(dir);
      final t = now ?? DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final name = '${t.year}${two(t.month)}${two(t.day)}-'
          '${two(t.hour)}${two(t.minute)}${two(t.second)}';
      final wavFile = File('${dir.path}/$name.wav');
      final wav = wavFile.openWrite()..add(_wavHeader(0));
      final csv = File('${dir.path}/$name.csv').openWrite()
        ..writeln('# $header')
        ..writeln(columns);
      return TunerRecording._(name, wavFile, wav, csv);
    } catch (e) {
      if (kDebugMode) debugPrint('[tuner] recording not started: $e');
      return null;
    }
  }

  void addPcm(Uint8List chunk) {
    if (_closed || _bytes >= maxSeconds * sampleRate * 2) return;
    _wav.add(chunk);
    _bytes += chunk.length;
  }

  void addFrame(TunerFrame f, TunerModel m, String status) {
    if (_closed) return;
    _at = f.at;
    final p = f.pitch, r = m.reading;
    String n(double? v, int places) => v == null ? '' : v.toStringAsFixed(places);
    _csv.writeln([
      n(f.at.inMicroseconds / 1e6, 4),
      n(p?.hz, 2),
      n(p?.clarity, 3),
      n(p?.rms, 5),
      m.lastDecision.name,
      m.lastOnset ? 1 : 0,
      r?.string.name ?? '',
      n(r?.cents, 2),
      r == null ? '' : (r.live ? 1 : 0),
      r == null ? '' : (r.inTune ? 1 : 0),
      r?.trend.name ?? '',
      _quote(status),
    ].join(','));
  }

  /// A row of its own at the latest frame's time: `event:<what>`.
  void event(String what) {
    if (_closed) return;
    _csv.writeln('${(_at.inMicroseconds / 1e6).toStringAsFixed(4)},,,,'
        'event:${what.replaceAll(',', ';')},,,,,,,');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _wav.close();
      await _csv.close();
      // The sizes were unknown at the start: patch them in.
      final raf = await _wavFile.open(mode: FileMode.writeOnlyAppend);
      await raf.setPosition(0);
      await raf.writeFrom(_wavHeader(_bytes));
      await raf.close();
    } catch (e) {
      if (kDebugMode) debugPrint('[tuner] recording close failed: $e');
    }
  }

  static String _quote(String s) =>
      s.contains(',') || s.contains('"') ? '"${s.replaceAll('"', '""')}"' : s;

  /// Deletes all but the newest keep - 1 sessions, to make room for one more.
  static Future<void> _prune(Directory dir) async {
    final names = <String>{
      await for (final e in dir.list())
        if (e is File && (e.path.endsWith('.wav') || e.path.endsWith('.csv')))
          e.uri.pathSegments.last.split('.').first,
    }.toList()
      ..sort();
    final excess = names.length - (keep - 1);
    for (final old in names.take(excess < 0 ? 0 : excess)) {
      for (final ext in ['wav', 'csv']) {
        final f = File('${dir.path}/$old.$ext');
        if (await f.exists()) await f.delete();
      }
    }
  }

  static Uint8List _wavHeader(int dataBytes) {
    final b = ByteData(44);
    void tag(int at, String s) {
      for (var i = 0; i < 4; i++) {
        b.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    b.setUint32(4, 36 + dataBytes, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, 1, Endian.little); // mono
    b.setUint32(24, sampleRate, Endian.little);
    b.setUint32(28, sampleRate * 2, Endian.little);
    b.setUint16(32, 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    b.setUint32(40, dataBytes, Endian.little);
    return b.buffer.asUint8List();
  }
}
