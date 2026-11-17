import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/piece.dart';
import 'package:violin_practice_companion/models/piece_media.dart';
import 'package:violin_practice_companion/models/section.dart';
import 'package:violin_practice_companion/services/piece_media_store.dart';
import 'package:violin_practice_companion/services/piece_repository.dart';
import 'package:violin_practice_companion/services/piece_share_bundle.dart';
import 'package:violin_practice_companion/services/piece_share_io.dart';
import 'package:violin_practice_companion/services/piece_storage_io.dart';

/// A teacher demo as the recorder wrote it before b13b197: separate audio and
/// video. (New demos are one video with sound, like [importedMp4]; these old
/// ones still exist on devices and still have to share.)
PieceMedia demo(String pieceId, String id, {String label = 'Teacher demo'}) =>
    PieceMedia(
      id: id,
      label: label,
      kind: MediaKind.recorded,
      alignmentKey: 'media:$pieceId:$id',
      audio: MediaRef.appFile('media/$pieceId/$id/audio.wav'),
      analysis: MediaRef.appFile('media/$pieceId/$id/audio.wav'),
      video: MediaRef.appFile('media/$pieceId/$id/video.mp4'),
      avOffsetMs: 42,
      contentStartSeconds: 1.5,
    );

/// An imported .mp4: one file is the audio, the analysis and the video.
PieceMedia importedMp4(String pieceId, String id) => PieceMedia(
      id: id,
      label: 'Lesson',
      kind: MediaKind.imported,
      alignmentKey: 'media:$pieceId:$id',
      audio: MediaRef.appFile('media/$pieceId/$id/source.mp4'),
      analysis: MediaRef.appFile('media/$pieceId/$id/source.mp4'),
      video: MediaRef.appFile('media/$pieceId/$id/source.mp4'),
    );

void main() {
  group('planShareExport', () {
    test('re-homes files to media/<id>/ and sends a shared file once', () {
      final plan = planShareExport([
        ShareMediaChoice(demo('p', 'demo_1')),
        ShareMediaChoice(importedMp4('p', 'import_2')),
      ]);
      expect(plan.files, {
        'media/demo_1/audio.wav': 'media/p/demo_1/audio.wav',
        'media/demo_1/video.mp4': 'media/p/demo_1/video.mp4',
        'media/import_2/source.mp4': 'media/p/import_2/source.mp4',
      });
      final d = plan.media.first;
      expect(d.audio, const MediaRef.appFile('media/demo_1/audio.wav'));
      expect(d.analysis, d.audio);
      expect(d.video, const MediaRef.appFile('media/demo_1/video.mp4'));
      expect(d.avOffsetMs, 42);
      expect(d.contentStartSeconds, 1.5);
    });

    test('leaving the video out drops it, and its offset, but not the audio',
        () {
      final plan = planShareExport([
        ShareMediaChoice(demo('p', 'demo_1'), includeVideo: false),
        ShareMediaChoice(importedMp4('p', 'import_2'), includeVideo: false),
      ]);
      expect(plan.files.keys,
          {'media/demo_1/audio.wav', 'media/import_2/source.mp4'});
      expect(plan.media[0].video, isNull);
      expect(plan.media[0].avOffsetMs, 0);
      // The mp4 still goes: it is the audio.
      expect(plan.media[1].audio,
          const MediaRef.appFile('media/import_2/source.mp4'));
      expect(plan.media[1].video, isNull);
    });

    test('a legacy teacher_recordings/ path arrives in the new layout', () {
      const legacy = PieceMedia(
        id: 'teacher_demo',
        label: 'Teacher demo',
        kind: MediaKind.recorded,
        alignmentKey: 'media:p:teacher_demo',
        audio: MediaRef.appFile('teacher_recordings/p/audio.wav'),
        analysis: MediaRef.appFile('teacher_recordings/p/audio.wav'),
      );
      final plan = planShareExport([const ShareMediaChoice(legacy)]);
      expect(plan.files,
          {'media/teacher_demo/audio.wav': 'teacher_recordings/p/audio.wav'});
    });

    test('bundled tracks and the synthesized score are never shared', () {
      final plan = planShareExport([
        const ShareMediaChoice(PieceMedia.synthesized),
        const ShareMediaChoice(PieceMedia(
          id: 'mix',
          label: 'Mix',
          kind: MediaKind.bundled,
          alignmentKey: 'bundled:x',
          audio: MediaRef.asset('assets/library/x/audio/mix.mp3'),
        )),
      ]);
      expect(plan.media, isEmpty);
      expect(plan.files, isEmpty);
    });
  });

  group('PieceShareManifest.fromJson', () {
    Map<String, Object?> manifest({List<Object?> media = const []}) => {
          'format': 1,
          'piece': {'id': 'tune_1', 'title': 'Tune', 'bundled': false},
          'media': media,
        };

    test('refuses a newer format with a message to update', () {
      expect(
          () => PieceShareManifest.fromJson({...manifest(), 'format': 99}),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('newer version'))));
    });

    test('drops a row whose files point outside its own folder', () {
      final good = planShareExport([ShareMediaChoice(demo('p', 'demo_1'))])
          .media
          .single
          .toJson();
      final escaping = {
        ...good,
        'id': 'demo_2',
        'audio': {'storage': 'appFile', 'path': 'media/demo_2/../../evil'},
      };
      final other = {
        ...good,
        'id': 'demo_3',
        'audio': {'storage': 'appFile', 'path': 'media/demo_1/audio.wav'},
      };
      final m = PieceShareManifest.fromJson(
          manifest(media: [good, escaping, other]));
      expect([for (final r in m.media) r.id], ['demo_1']);
    });

    test('refuses an id that could name a path', () {
      expect(
          () => PieceShareManifest.fromJson({
                ...manifest(),
                'piece': {'id': '../x', 'title': 'T'},
              }),
          throwsFormatException);
    });
  });

  group('planShareImport', () {
    final shared = PieceShareManifest(
      pieceId: 'tune_1',
      title: 'Tune',
      bundled: false,
      hasSections: false,
      media: planShareExport([
        ShareMediaChoice(demo('tune_1', 'demo_1')),
        ShareMediaChoice(demo('tune_1', 'teacher_demo')),
      ]).media,
      alignments: {'demo_1': '{"a":1}'},
    );

    test('re-homes under the receiver piece id, alignment key included', () {
      final plan = planShareImport(shared,
          pieceId: 'tune_9',
          score: ShareScoreAction.create,
          existing: const [],
          identical: const {},
          freshMediaId: (i) => 'shared_$i');
      final d = plan.media.first;
      expect(d.media.alignmentKey, 'media:tune_9:demo_1');
      expect(d.media.audio,
          const MediaRef.appFile('media/tune_9/demo_1/audio.wav'));
      expect(d.files['media/demo_1/video.mp4'],
          'media/tune_9/demo_1/video.mp4');
      expect(d.alignment, '{"a":1}');
      expect(plan.media[1].alignment, isNull);
    });

    test('skips a recording already here; renames a different one sharing '
        'its id', () {
      final plan = planShareImport(shared,
          pieceId: 'tune_1',
          score: ShareScoreAction.keep,
          existing: [demo('tune_1', 'demo_1'), demo('tune_1', 'teacher_demo')],
          identical: const {'demo_1'},
          freshMediaId: (i) => 'shared_$i');
      expect(plan.alreadyPresent, 1);
      expect([for (final p in plan.media) p.media.id], ['shared_0']);
      expect(plan.media.single.media.alignmentKey, 'media:tune_1:shared_0');
    });
  });

  test('shareFileNameFor makes the title safe as a file name', () {
    expect(shareFileNameFor('Gavotte / Gossec: "B"'),
        'Gavotte Gossec B .stringlings'.replaceAll(' .', '.'));
    expect(shareFileNameFor('...'), 'Piece.stringlings');
  });

  // ── io: export on one device, import on another ─────────────────────────

  group('PieceShareIo round trip', () {
    late Directory sender, receiver, temp;
    late String xml;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      sender = await Directory.systemTemp.createTemp('share_sender');
      receiver = await Directory.systemTemp.createTemp('share_receiver');
      temp = await Directory.systemTemp.createTemp('share_temp');
      xml = File('assets/library/lightly_row/score.musicxml')
          .readAsStringSync();
    });

    tearDown(() async {
      for (final d in [sender, receiver, temp]) {
        if (await d.exists()) await d.delete(recursive: true);
      }
    });

    Future<void> writeFile(Directory root, String rel, int size) async {
      final f = File('${root.path}/$rel');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(List.filled(size, 7));
    }

    /// Exports `tune_1` with one demo from [sender] (prefs are shared by the
    /// mock, so the alignment and display pref are set here, then cleared
    /// before the receiver side runs).
    Future<String> exportFromSender({bool includeVideo = true}) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'mediaAlignment.media:tune_1:demo_1', '{"anchors":[]}');
      await prefs.setString('display.numbers.tune_1', 'fingers');
      await writeFile(sender, 'media/tune_1/demo_1/audio.wav', 1000);
      await writeFile(sender, 'media/tune_1/demo_1/video.mp4', 5000);
      final io = PieceShareIo(docs: sender, temp: temp);
      final choices = [
        ShareMediaChoice(demo('tune_1', 'demo_1'), includeVideo: includeVideo)
      ];
      expect(await io.estimateBytes(choices), includeVideo ? 6000 : 1000);
      final path = await io.export(
        pieceId: 'tune_1',
        title: 'Lightly Row (scan)',
        bundled: false,
        musicXml: xml,
        sections: [const Section(label: 'A', startMeasure: 1)],
        choices: choices,
      );
      await prefs.clear();
      return path;
    }

    Future<ShareImportResult?> importOnReceiver(
      String path, {
      List<Piece> pieces = const [],
      ShareConflictChoice? onConflict,
      void Function()? conflictAsked,
    }) async {
      final io = PieceShareIo(docs: receiver, temp: temp);
      final share = await io.open(path);
      try {
        return await io.apply(
          share,
          repo: PieceRepository(storage: PieceStorage(root: receiver)),
          pieces: pieces,
          onScoreConflict: (_) async {
            conflictAsked?.call();
            return onConflict;
          },
          now: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        );
      } finally {
        await share.dispose();
      }
    }

    test('a new piece arrives under the sender id with its recording',
        () async {
      final path = await exportFromSender();
      expect(path, endsWith('/Lightly Row (scan).stringlings'));

      final result = await importOnReceiver(path);
      expect(result!.pieceId, 'tune_1');
      expect(result.score, ShareScoreAction.create);
      expect(result.added, 1);

      expect(
          File('${receiver.path}/scanned_pieces/tune_1.musicxml')
              .readAsStringSync(),
          xml);
      final index = jsonDecode(
          File('${receiver.path}/scanned_pieces/index.json')
              .readAsStringSync()) as Map;
      expect(index['pieces'], [
        {'id': 'tune_1', 'title': 'Lightly Row (scan)'}
      ]);
      expect(
          File('${receiver.path}/section_overrides/tune_1.sections.json')
              .existsSync(),
          isTrue);
      expect(
          File('${receiver.path}/media/tune_1/demo_1/video.mp4').lengthSync(),
          5000);

      final rows = await PieceMediaStore().load('tune_1');
      expect(rows.single.audio,
          const MediaRef.appFile('media/tune_1/demo_1/audio.wav'));
      expect(rows.single.avOffsetMs, 42);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('mediaAlignment.media:tune_1:demo_1'),
          '{"anchors":[]}');
      expect(prefs.getString('display.numbers.tune_1'), 'fingers');
    });

    test('sharing the same piece again adds nothing', () async {
      final path = await exportFromSender();
      await importOnReceiver(path);
      final storage = PieceStorage(root: receiver);
      final pieces = await storage.loadScannedPieces();
      final again = await importOnReceiver(path, pieces: pieces);
      expect(again!.score, ShareScoreAction.keep);
      expect(again.added, 0);
      expect(again.alreadyPresent, 1);
      expect(await PieceMediaStore().load('tune_1'), hasLength(1));
    });

    test('different music: keep both makes a second piece, cancel nothing',
        () async {
      final path = await exportFromSender(includeVideo: false);
      // The receiver's tune_1 is a different tune.
      final storage = PieceStorage(root: receiver);
      await storage.saveScannedPieceAs('tune_1', 'Mine',
          File('assets/library/happy_farmer/score.musicxml').readAsStringSync());
      final pieces = await storage.loadScannedPieces();

      var asked = 0;
      expect(
          await importOnReceiver(path,
              pieces: pieces, conflictAsked: () => asked++),
          isNull);
      expect(asked, 1);
      expect(await PieceMediaStore().load('tune_1'), isEmpty);

      final both = await importOnReceiver(path,
          pieces: pieces, onConflict: ShareConflictChoice.keepBoth);
      expect(both!.pieceId, 'lightly_row_scan_1700000000000');
      expect(both.score, ShareScoreAction.create);
      final rows = await PieceMediaStore().load(both.pieceId);
      expect(rows.single.video, isNull);
      expect(
          File('${receiver.path}/media/${both.pieceId}/demo_1/video.mp4')
              .existsSync(),
          isFalse);
      expect((await storage.loadScannedPieces()).map((p) => p.title),
          ['Mine', 'Lightly Row (scan)']);
    });

    test('a catalog piece this build lacks arrives under a fresh id',
        () async {
      final io = PieceShareIo(docs: sender, temp: temp);
      final path = await io.export(
        pieceId: 'some_future_catalog_tune',
        title: 'Future Tune',
        bundled: true,
        musicXml: xml,
        sections: const [],
        choices: const [],
      );
      final result = await importOnReceiver(path);
      expect(result!.pieceId, 'future_tune_1700000000000');
    });

    test('a file that is not a share is refused, and leaves nothing behind',
        () async {
      final bogus = File('${temp.path}/x.stringlings')
        ..writeAsStringSync('not a zip');
      await expectLater(PieceShareIo(docs: receiver, temp: temp).open(bogus.path),
          throwsFormatException);

      // A zip without a manifest.
      final zipPath = '${temp.path}/y.stringlings';
      final enc = ZipFileEncoder()..create(zipPath);
      enc.addArchiveFile(ArchiveFile.string('hello.txt', 'hi'));
      await enc.close();
      await expectLater(PieceShareIo(docs: receiver, temp: temp).open(zipPath),
          throwsFormatException);
      expect(
          temp.listSync().whereType<Directory>().where(
              (d) => d.path.split('/').last.startsWith('share_in_')),
          isEmpty);
    });
  });
}
