// Aligns every recording in the dev library with the aligner as it is now,
// and writes the barline times to a JSON snapshot. Two snapshots, taken
// before and after an aligner change, are compared by
// `scripts/alignment_diff.py`, which warns about every recording that moved:
// the alignment tests pin a handful of recordings, this covers all of them.
//
//   ALIGN_SNAPSHOT_OUT=/tmp/after.json flutter test test/alignment_corpus_snapshot_test.dart
//
// Skips unless ALIGN_SNAPSHOT_OUT is set and the dev library is present
// ($VPC_DEV_LIBRARY, else ../violin_dev_library). Decoding uses macOS
// `afconvert` (native rate, channels mixed down), cached in
// $ALIGN_DECODE_CACHE (default: the system temp dir).
//
// With ALIGN_SNAPSHOT_STORED=1 it aligns nothing and snapshots the
// alignments the library already holds (state.json `alignments`), as synced
// from a device: diff that against a fresh snapshot to see whether a device
// is running what the current aligner would give.
//
// The recordings are not ours; the snapshot holds only timings, but keep it
// out of this repo anyway.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/audio_score_auto_aligner.dart';
import 'package:violin_practice_companion/services/piece_aligner.dart';
import 'package:violin_practice_companion/services/media_playback_service.dart';
import 'package:violin_practice_companion/services/midi_generator.dart';
import 'package:musicxml_tools/musicxml_tools.dart';

void main() {
  final out = Platform.environment['ALIGN_SNAPSHOT_OUT'];
  final library = Directory(
      Platform.environment['VPC_DEV_LIBRARY'] ?? '../violin_dev_library');
  final state = File('${library.path}/state.json');
  final skip = out == null
      ? 'set ALIGN_SNAPSHOT_OUT to take a snapshot'
      : !state.existsSync()
          ? 'needs the dev library (set VPC_DEV_LIBRARY)'
          : null;

  test('snapshot every dev-library alignment', skip: skip, () {
    final json = jsonDecode(state.readAsStringSync()) as Map<String, dynamic>;
    final cache = Directory(Platform.environment['ALIGN_DECODE_CACHE'] ??
        '${Directory.systemTemp.path}/vpc_align_decode')
      ..createSync(recursive: true);
    final snapshot = <String, Object>{};
    final fromStored = Platform.environment['ALIGN_SNAPSHOT_STORED'] == '1';

    final pieceMedia = (json['pieceMedia'] as Map).cast<String, dynamic>();
    for (final MapEntry(key: pieceId, value: rows) in pieceMedia.entries) {
      final score = _scoreFor(pieceId, library);
      if (score == null) {
        // ignore: avoid_print
        print('[snapshot] $pieceId: no score, skipped');
        continue;
      }
      final piece = MusicXmlParser()
          .parse(MusicXmlNormalizer.toSoundingPitch(score.readAsStringSync()));
      for (final row in (rows as List).cast<Map<String, dynamic>>()) {
        final ref = (row['analysis'] ?? row['audio']) as Map<String, dynamic>?;
        if (ref == null || ref['storage'] != 'appFile') continue;
        final src = File('${library.path}/${ref['path']}');
        if (!src.existsSync()) continue;
        final key = row['alignmentKey'] as String;
        final AutoAlignmentResult result;
        if (fromStored) {
          final raw = (json['alignments'] as Map?)?[key];
          if (raw is! String) continue;
          final a = jsonDecode(raw) as Map<String, dynamic>;
          result = AutoAlignmentResult(
            [
              for (final x in (a['anchors'] as List).cast<Map>())
                ScoreAudioAnchor((x['scoreMs'] as num).toDouble(),
                    (x['audioSec'] as num).toDouble()),
            ],
            a['generationBpm'] as int,
            0,
            hasCompressedAnchors: a['hasCompressedAnchors'] as bool? ?? false,
          );
        } else {
          final wav = _decoded(src, cache);
          result = AudioScoreAutoAligner(midiGenerator: MidiGenerator.forTest())
              .align(piece, wav.readAsBytesSync(),
                  contentStartSeconds:
                      (row['contentStartSeconds'] as num?)?.toDouble(),
                  contentEndSeconds:
                      (row['contentEndSeconds'] as num?)?.toDouble());
        }
        final midi =
            MidiGenerator.forTest().generate(piece, result.generationBpm);
        // The anchors as playback uses them (MediaPlaybackService.load).
        final anchors = MediaPlaybackService.dropDegenerateSegments(
            MediaPlaybackService.sortAnchors(result.anchors));
        final bars = [
          for (final s in midi.measureOnsetSeconds) _audioAt(anchors, s * 1000),
        ];
        snapshot[row['alignmentKey'] as String] = {
          'pieceId': pieceId,
          'label': row['label'],
          'bpm': result.generationBpm,
          'compressed': result.hasCompressedAnchors,
          'bars': [for (final b in bars) double.parse(b.toStringAsFixed(3))],
          // Playing order repeats bars; ratings name bars by number.
          'numbers': midi.measureNumbers,
          if (row['alignmentRating'] != null) 'rating': row['alignmentRating'],
        };
        // ignore: avoid_print
        print('[snapshot] ${row['alignmentKey']}: ${bars.length} bars, '
            'bpm ${result.generationBpm}');
      }
    }
    File(out!).writeAsStringSync(
        const JsonEncoder.withIndent(' ').convert(snapshot));
    // ignore: avoid_print
    print('[snapshot] ${snapshot.length} alignments -> $out');
  }, timeout: const Timeout(Duration(minutes: 30)));
}

File? _scoreFor(String pieceId, Directory library) {
  for (final path in [
    'assets/library/$pieceId/score.musicxml',
    '${library.path}/scanned_pieces/$pieceId.musicxml',
    '${library.path}/editable_fixtures/$pieceId.musicxml',
  ]) {
    final f = File(path);
    if (f.existsSync()) return f;
  }
  return null;
}

/// [src] as a mono WAV at its own sample rate, decoded once per version.
File _decoded(File src, Directory cache) {
  final stat = src.statSync();
  final name = '${src.path.hashCode.toRadixString(16)}_'
      '${stat.size}_${stat.modified.millisecondsSinceEpoch}.wav';
  final wav = File('${cache.path}/$name');
  if (wav.existsSync()) return wav;
  // --mix refuses a file that is already mono; that one needs no mixing.
  for (final mix in [true, false]) {
    final r = Process.runSync('afconvert', [
      '-f', 'WAVE', '-d', 'LEI16', '-c', '1', if (mix) '--mix', //
      src.path, wav.path,
    ]);
    if (r.exitCode == 0) return wav;
    if (!mix) throw StateError('afconvert ${src.path}: ${r.stderr}');
  }
  return wav;
}

/// Audio time of [ms] of score time, interpolated as playback does.
double _audioAt(List<ScoreAudioAnchor> a, double ms) {
  var k = 0;
  while (k + 2 < a.length && a[k + 1].scoreMs <= ms) {
    k++;
  }
  if (a[k + 1].scoreMs == a[k].scoreMs) return a[k].audioSec;
  return a[k].audioSec +
      (a[k + 1].audioSec - a[k].audioSec) *
          (ms - a[k].scoreMs) /
          (a[k + 1].scoreMs - a[k].scoreMs);
}
