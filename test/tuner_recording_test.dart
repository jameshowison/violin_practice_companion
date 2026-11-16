import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:string_tuner/string_tuner.dart';
import 'package:violin_practice_companion/services/tuner_input_base.dart';
import 'package:violin_practice_companion/services/tuner_model.dart';
import 'package:violin_practice_companion/services/tuner_recording_io.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('tuner_rec'));
  tearDown(() => root.deleteSync(recursive: true));

  test('writes a playable WAV and a row per frame, aligned in time', () async {
    final rec = (await TunerRecording.start(
        header: 'instrument=Violin a4=440', root: root, now: DateTime(2026, 11, 14, 9, 5, 7)))!;
    expect(rec.name, '20261114-090507');
    final model = TunerModel(InstrumentTuning.violin())..pinned = 'A4';
    final pcm = Uint8List(4800 * 2); // 0.1 s of silence
    rec.addPcm(pcm);
    rec.addPcm(pcm);
    for (var i = 0; i < 20; i++) {
      final f = TunerFrame(Duration(microseconds: (i * 512 * 1e6 / 48000).round()),
          PitchEstimate(hz: 438, clarity: 0.97, rms: 0.05));
      model.add(f);
      rec.addFrame(f, model, 'Flat, a bit');
    }
    rec.event('mark');
    await rec.close();

    final wav = File('${root.path}/tuner_sessions/20261114-090507.wav').readAsBytesSync();
    final h = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(h.getUint32(4, Endian.little), 36 + 19200);
    expect(h.getUint32(24, Endian.little), 48000);
    expect(h.getUint32(40, Endian.little), 19200);
    expect(wav.length, 44 + 19200);

    final csv = File('${root.path}/tuner_sessions/20261114-090507.csv').readAsLinesSync();
    expect(csv[0], '# instrument=Violin a4=440');
    expect(csv[1], TunerRecording.columns);
    expect(csv.length, 2 + 20 + 1);
    final first = csv[2].split(',');
    expect(first[0], '0.0000');
    expect(first[4], 'attack');
    expect(first[5], '1', reason: 'the first frame starts the note');
    final last = csv[21].split(',');
    expect(last[4], 'accepted');
    expect(last[6], 'A4');
    expect(double.parse(last[7]), closeTo(-7.89, 0.01));
    expect(csv[21], endsWith('"Flat, a bit"'));
    expect(csv[22], startsWith('${last[0]},,,,event:mark'));
  });

  test('keeps only the newest sessions', () async {
    for (var i = 0; i < TunerRecording.keep + 3; i++) {
      final rec = await TunerRecording.start(
          header: '', root: root, now: DateTime(2026, 11, 14, 10, 0, i));
      await rec!.close();
    }
    final names = Directory('${root.path}/tuner_sessions')
        .listSync()
        .map((e) => e.uri.pathSegments.last)
        .toList()
      ..sort();
    expect(names.length, 2 * TunerRecording.keep);
    expect(names.first, '20261114-100003.csv');
  });
}
