import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/piece_media.dart';
import 'package:violin_practice_companion/services/media_alignment_store.dart';
import 'package:violin_practice_companion/services/media_migration.dart';
import 'package:violin_practice_companion/services/piece_media_store.dart';

/// A teacher recording as the pre-[PieceMedia] build stored it: absolute paths
/// into a data container whose UUID is exactly the part that does not survive.
String legacyRecording({
  String container = '15C986F6-0000-0000-0000-000000000000',
  String pieceId = 'galopede',
}) =>
    '{"videoPath":"/var/mobile/Containers/Data/Application/$container/'
    'Documents/teacher_recordings/$pieceId/video.mp4",'
    '"audioPath":"/var/mobile/Containers/Data/Application/$container/'
    'Documents/teacher_recordings/$pieceId/audio.wav",'
    '"avOffsetMs":42,"generationBpm":143,"hasCompressedAnchors":true,'
    '"anchors":[{"scoreMs":0.0,"audioSec":3.1},'
    '{"scoreMs":1000.0,"audioSec":4.2},'
    '{"scoreMs":2000.0,"audioSec":5.3}]}';

void main() {
  void usePrefs(Map<String, Object> initial) {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(initial);
  }

  group('relativizeLegacyPath', () {
    test('drops the container prefix that does not survive', () {
      const stored = '/var/mobile/Containers/Data/Application/'
          '15C986F6-0000-0000-0000-000000000000/Documents/'
          'teacher_recordings/galopede/audio.wav';
      expect(MediaMigration.relativizeLegacyPath(stored),
          'teacher_recordings/galopede/audio.wav');
    });

    test('works on Android, whose documents directory is named differently',
        () {
      // The reason the anchor is the recordings folder and not "/Documents/":
      // Android's documents directory is `.../app_flutter`.
      const stored = '/data/user/0/com.example.violin_practice_companion/'
          'app_flutter/teacher_recordings/galopede/audio.wav';
      expect(MediaMigration.relativizeLegacyPath(stored),
          'teacher_recordings/galopede/audio.wav');
    });

    test('passes an already-relative path through unchanged', () {
      expect(MediaMigration.relativizeLegacyPath('teacher_recordings/p/a.wav'),
          'teacher_recordings/p/a.wav');
    });

    test('returns null for a path it cannot place', () {
      expect(MediaMigration.relativizeLegacyPath('/tmp/somewhere/else.wav'),
          isNull);
    });
  });

  group('migrateTeacherRecording', () {
    test('turns a legacy blob into one medium with relative refs', () async {
      usePrefs({'teacherRecording.galopede': legacyRecording()});

      final media = await const MediaMigration().migrateTeacherRecording('galopede');

      expect(media, isNotNull);
      expect(media!.kind, MediaKind.recorded);
      expect(media.label, 'Teacher demo');
      expect(media.avOffsetMs, 42);
      // The point of the whole exercise: no absolute path survives.
      expect(media.audio!.storage, MediaStorage.appFile);
      expect(media.audio!.path, 'teacher_recordings/galopede/audio.wav');
      expect(media.video!.path, 'teacher_recordings/galopede/video.mp4');
      // The capture wrote WAV so it could be aligned; it is its own analysis
      // source.
      expect(media.analysis, media.audio);
      expect(media.canAlign, isTrue);
    });

    test('carries the anchors across so nothing has to realign', () async {
      usePrefs({'teacherRecording.galopede': legacyRecording()});

      final media = await const MediaMigration().migrateTeacherRecording('galopede');
      final alignment =
          await MediaAlignmentStore().load(media!.alignmentKey);

      expect(alignment, isNotNull);
      expect(alignment!.generationBpm, 143);
      expect(alignment.hasCompressedAnchors, isTrue);
      expect(alignment.anchors, hasLength(3));
      expect(alignment.anchors.first.audioSec, 3.1);
    });

    test('persists the medium, so the catalog finds it next time', () async {
      usePrefs({'teacherRecording.galopede': legacyRecording()});

      await const MediaMigration().migrateTeacherRecording('galopede');

      final stored = await PieceMediaStore().load('galopede');
      expect(stored, hasLength(1));
      expect(stored.single.id, MediaMigration.migratedRecordingId);
    });

    test('is idempotent — a second run does not duplicate anything', () async {
      usePrefs({'teacherRecording.galopede': legacyRecording()});
      final migration = const MediaMigration();

      await migration.migrateTeacherRecording('galopede');
      final second = await migration.migrateTeacherRecording('galopede');

      expect(second, isNull, reason: 'nothing left to do');
      expect(await PieceMediaStore().load('galopede'), hasLength(1));
    });

    test('leaves a piece that already has user media alone', () async {
      usePrefs({
        'teacherRecording.galopede': legacyRecording(),
        'pieceMedia.galopede': '[]',
      });

      expect(await const MediaMigration().migrateTeacherRecording('galopede'),
          isNull);
    });

    test('a piece with no legacy recording has nothing to migrate', () async {
      usePrefs({});
      expect(await const MediaMigration().migrateTeacherRecording('p1'), isNull);
    });

    test('an unplaceable path is treated as no recording, not a broken one',
        () async {
      // Same policy the old store applied to any parse failure: re-recording
      // is the recovery. Better than persisting a ref that resolves nowhere.
      usePrefs({
        'teacherRecording.p1': '{"videoPath":"/tmp/v.mp4",'
            '"audioPath":"/tmp/a.wav","avOffsetMs":0,"generationBpm":100,'
            '"anchors":[{"scoreMs":0.0,"audioSec":0.0},'
            '{"scoreMs":1000.0,"audioSec":1.0}]}'
      });
      expect(await const MediaMigration().migrateTeacherRecording('p1'), isNull);
    });

    test('unparseable legacy data is treated as no recording', () async {
      usePrefs({'teacherRecording.p1': 'not json'});
      expect(await const MediaMigration().migrateTeacherRecording('p1'), isNull);
    });

    test('a legacy blob with too few anchors is not migrated', () async {
      usePrefs({
        'teacherRecording.p1': '{"videoPath":"x/teacher_recordings/p1/v.mp4",'
            '"audioPath":"x/teacher_recordings/p1/a.wav","avOffsetMs":0,'
            '"generationBpm":100,"anchors":[{"scoreMs":0.0,"audioSec":0.0}]}'
      });
      expect(await const MediaMigration().migrateTeacherRecording('p1'), isNull);
    });
  });

  group('migrateBundledAnchors', () {
    const legacyAnchors = '{"generationBpm":168,"hasCompressedAnchors":false,'
        '"anchors":[{"scoreMs":0.0,"audioSec":0.0},'
        '{"scoreMs":1000.0,"audioSec":1.1}]}';

    test('moves a cached Play Along alignment onto the bundled key', () async {
      usePrefs({'audioSyncAnchors.lightly_row': legacyAnchors});
      final key = MediaMigration.bundledAlignmentKey('lightly_row');

      await const MediaMigration().migrateBundledAnchors('lightly_row', key);

      final alignment = await MediaAlignmentStore().load(key);
      expect(alignment, isNotNull,
          reason: 'an already-aligned piece must not re-align');
      expect(alignment!.generationBpm, 168);
      expect(alignment.anchors, hasLength(2));
    });

    test('does not overwrite an alignment that is already there', () async {
      final key = MediaMigration.bundledAlignmentKey('lightly_row');
      usePrefs({
        'audioSyncAnchors.lightly_row': legacyAnchors,
        'mediaAlignment.$key': '{"generationBpm":999,"anchors":['
            '{"scoreMs":0.0,"audioSec":0.0},{"scoreMs":1.0,"audioSec":1.0}]}'
      });

      await const MediaMigration().migrateBundledAnchors('lightly_row', key);

      expect((await MediaAlignmentStore().load(key))!.generationBpm, 999);
    });

    test('a never-aligned piece has nothing to migrate', () async {
      usePrefs({});
      final key = MediaMigration.bundledAlignmentKey('lightly_row');
      await const MediaMigration().migrateBundledAnchors('lightly_row', key);
      expect(await MediaAlignmentStore().load(key), isNull);
    });

    test('a legacy blob that no longer parses is dropped, not carried over',
        () async {
      usePrefs({'audioSyncAnchors.lightly_row': 'not json'});
      final key = MediaMigration.bundledAlignmentKey('lightly_row');
      await const MediaMigration().migrateBundledAnchors('lightly_row', key);
      expect(await MediaAlignmentStore().load(key), isNull);
    });
  });
}
