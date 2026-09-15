import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/piece_media.dart';
import 'package:violin_practice_companion/services/media_catalog.dart';
import 'package:violin_practice_companion/services/media_migration.dart';
import 'package:violin_practice_companion/services/piece_media_store.dart';

import 'media_migration_test.dart' show legacyRecording;

void main() {
  void usePrefs(Map<String, Object> initial) {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(initial);
  }

  group('bundledMediaFor', () {
    test('offers the three mixes, playing the mp3 the user chose', () {
      final media = MediaCatalog.bundledMediaFor('lightly_row');

      expect(media.map((m) => m.label), ['Mix', 'Melody', 'Chords']);
      expect(media.map((m) => m.audio!.path), [
        'assets/audio/lightly_row/mix.mp3',
        'assets/audio/lightly_row/melody.mp3',
        'assets/audio/lightly_row/chords.mp3',
      ]);
      expect(media.every((m) => m.audio!.isAsset), isTrue);
      expect(media.every((m) => m.kind == MediaKind.bundled), isTrue);
      expect(media.every((m) => m.isRemovable), isFalse);
    });

    test('analyses melody.wav whichever mix is playing', () {
      // The closest match to the score's own notes, and so the
      // best-conditioned DTW reference — not whichever track is being heard.
      final media = MediaCatalog.bundledMediaFor('lightly_row');
      for (final m in media) {
        expect(m.analysis!.path, 'assets/audio/lightly_row/melody.wav');
        expect(m.analysis!.isWav, isTrue);
      }
    });

    test('all three share one alignment key, so alignment runs once', () {
      final keys =
          MediaCatalog.bundledMediaFor('salt_creek').map((m) => m.alignmentKey);
      expect(keys.toSet(), hasLength(1));
      expect(keys.first, MediaMigration.bundledAlignmentKey('salt_creek'));
    });

    test('two pieces do not share an alignment key', () {
      expect(MediaCatalog.bundledMediaFor('lightly_row').first.alignmentKey,
          isNot(MediaCatalog.bundledMediaFor('salt_creek').first.alignmentKey));
    });
  });

  group('mediaFor', () {
    test('a plain piece can still be played — by the score itself', () async {
      usePrefs({});
      final media =
          await MediaCatalog().mediaFor('happy_farmer', audioFolder: null);

      expect(media, [PieceMedia.synthesized]);
      expect(media.single.isSynthesized, isTrue);
    });

    test('the synthesized score is always first', () async {
      usePrefs({});
      final media =
          await MediaCatalog().mediaFor('lightly_row', audioFolder: 'lightly_row');

      expect(media.first, PieceMedia.synthesized);
      expect(media.map((m) => m.label),
          ['Simulated', 'Mix', 'Melody', 'Chords']);
    });

    test('user media come after the bundled ones', () async {
      usePrefs({});
      await PieceMediaStore().add(
        'lightly_row',
        const PieceMedia(
          id: 'import_1',
          label: 'Lesson 3',
          kind: MediaKind.imported,
          alignmentKey: 'media:lightly_row:import_1',
          audio: MediaRef.appFile('media/lightly_row/import_1/source.m4a'),
          analysis: MediaRef.appFile('media/lightly_row/import_1/source.m4a'),
        ),
      );

      final media =
          await MediaCatalog().mediaFor('lightly_row', audioFolder: 'lightly_row');

      expect(media.map((m) => m.label),
          ['Simulated', 'Mix', 'Melody', 'Chords', 'Lesson 3']);
      expect(media.last.isRemovable, isTrue);
    });

    test('a legacy teacher recording shows up without a separate step',
        () async {
      usePrefs({'teacherRecording.galopede': legacyRecording()});

      final media =
          await MediaCatalog().mediaFor('galopede', audioFolder: null);

      expect(media.map((m) => m.label), ['Simulated', 'Teacher demo']);
      expect(media.last.audio!.path, 'teacher_recordings/galopede/audio.wav');
    });
  });

  group('resolve', () {
    final media = [
      PieceMedia.synthesized,
      ...MediaCatalog.bundledMediaFor('lightly_row'),
    ];

    test('finds the medium an id names', () {
      expect(MediaCatalog.resolve(media, 'bundled_chords').label, 'Chords');
    });

    test('null means the synthesized score', () {
      expect(MediaCatalog.resolve(media, null), PieceMedia.synthesized);
    });

    test('a selection that outlived its medium falls back to something playable',
        () {
      // What happens when the selected recording has just been deleted.
      expect(MediaCatalog.resolve(media, 'demo_gone_now'),
          PieceMedia.synthesized);
    });
  });
}
