import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/models/piece_media.dart';
import 'package:violin_practice_companion/services/audio_score_auto_aligner.dart';
import 'package:violin_practice_companion/services/media_alignment_store.dart';
import 'package:violin_practice_companion/services/piece_media_store.dart';

void main() {
  void useStore(Map<String, Object> initial) {
    TestWidgetsFlutterBinding.ensureInitialized();
    // SharedPreferences caches its instance, and mock values are only picked
    // up on a fresh getInstance().
    SharedPreferences.setMockInitialValues(initial);
  }

  PieceMedia recording(String id) => PieceMedia(
        id: id,
        label: 'Teacher demo',
        kind: MediaKind.recorded,
        alignmentKey: 'media:p1:$id',
        audio: MediaRef.appFile('media/p1/$id/audio.wav'),
        analysis: MediaRef.appFile('media/p1/$id/audio.wav'),
        video: MediaRef.appFile('media/p1/$id/video.mp4'),
        avOffsetMs: 37,
      );

  group('MediaRef', () {
    test('round-trips through JSON keeping its storage kind', () {
      const asset = MediaRef.asset('assets/audio/lightly_row/mix.mp3');
      const file = MediaRef.appFile('media/p1/demo/audio.wav');

      expect(MediaRef.fromJson(asset.toJson()), asset);
      expect(MediaRef.fromJson(file.toJson()), file);
      expect(MediaRef.fromJson(asset.toJson())!.isAsset, isTrue);
      expect(MediaRef.fromJson(file.toJson())!.isAsset, isFalse);
    });

    test('reads the extension, and knows which files skip the decoder', () {
      expect(const MediaRef.appFile('media/p1/d/audio.wav').extension, 'wav');
      expect(const MediaRef.appFile('media/p1/d/audio.wav').isWav, isTrue);
      expect(const MediaRef.appFile('media/p1/d/source.M4A').extension, 'm4a');
      expect(const MediaRef.appFile('media/p1/d/source.M4A').isWav, isFalse);
      // A dot in a directory name is not an extension.
      expect(const MediaRef.appFile('media/my.files/track').extension, '');
    });

    test('rejects malformed JSON rather than inventing a ref', () {
      expect(MediaRef.fromJson(null), isNull);
      expect(MediaRef.fromJson('nonsense'), isNull);
      expect(MediaRef.fromJson({'path': 'a.wav'}), isNull); // no storage
      expect(MediaRef.fromJson({'storage': 'asset'}), isNull); // no path
      expect(MediaRef.fromJson({'storage': 'carrier_pigeon', 'path': 'a.wav'}),
          isNull);
    });
  });

  group('PieceMedia', () {
    test('the synthesized score carries no files and cannot be removed', () {
      const media = PieceMedia.synthesized;
      expect(media.isSynthesized, isTrue);
      expect(media.audio, isNull);
      expect(media.canAlign, isFalse);
      expect(media.isRemovable, isFalse);
    });

    test('round-trips every field', () {
      final media = recording('demo_1');
      final restored = PieceMedia.fromJson(media.toJson());
      expect(restored, media);
      expect(restored!.video, isNotNull);
      expect(restored.avOffsetMs, 37);
      expect(restored.canAlign, isTrue);
      expect(restored.isRemovable, isTrue);
    });

    test('a content window round-trips, and is absent when unset', () {
      final plain = recording('demo_1');
      expect(plain.contentStartSeconds, isNull);
      expect(plain.contentEndSeconds, isNull);
      // Not written at all when unset, so an un-annotated medium and one
      // stored before content windows existed are the same bytes.
      expect(plain.toJson().containsKey('contentStartSeconds'), isFalse);
      expect(plain.toJson().containsKey('contentEndSeconds'), isFalse);

      final windowed =
          plain.withContentWindow(startSeconds: 3.0, endSeconds: 49.0);
      final restored = PieceMedia.fromJson(windowed.toJson());
      expect(restored, windowed);
      expect(restored!.contentStartSeconds, 3.0);
      expect(restored.contentEndSeconds, 49.0);
      // The window is part of the medium's identity — the transport reloads on
      // a change, and it only sees one if these differ.
      expect(windowed, isNot(plain));
    });

    test('an entry stored before content windows existed reads as unset', () {
      final legacy = PieceMedia.fromJson({
        'id': 'demo_1',
        'label': 'Teacher demo',
        'kind': 'recorded',
        'alignmentKey': 'media:p1:demo_1',
        'avOffsetMs': 0,
      });
      expect(legacy, isNotNull);
      expect(legacy!.contentStartSeconds, isNull);
      expect(legacy.contentEndSeconds, isNull);
    });

    test('withContentWindow clears on null, where copyWith would not', () {
      final windowed = recording('demo_1')
          .withContentWindow(startSeconds: 3.0, endSeconds: 49.0);

      // Clearing back to "work it out from the audio" has to be expressible:
      // it is what a user does when their first guess made things worse.
      final cleared = windowed.withContentWindow();
      expect(cleared.contentStartSeconds, isNull);
      expect(cleared.contentEndSeconds, isNull);
      expect(cleared, recording('demo_1'));

      // One end only is a legitimate answer, not an incomplete one.
      final startOnly = windowed.withContentWindow(startSeconds: 3.0);
      expect(startOnly.contentStartSeconds, 3.0);
      expect(startOnly.contentEndSeconds, isNull);

      // copyWith keeps the window, because its nulls mean "unchanged".
      expect(windowed.copyWith(label: 'Take one').contentStartSeconds, 3.0);
    });

    test('a medium with no analysis source plays but cannot align', () {
      const media = PieceMedia(
        id: 'i1',
        label: 'Lesson',
        kind: MediaKind.imported,
        alignmentKey: 'media:p1:i1',
        audio: MediaRef.appFile('media/p1/i1/source.mp4'),
      );
      expect(media.canAlign, isFalse);
      expect(PieceMedia.fromJson(media.toJson()), media);
    });
  });

  group('PieceMediaStore', () {
    test('a piece with nothing added has no user media', () async {
      useStore({});
      expect(await PieceMediaStore().load('p1'), isEmpty);
      expect(await PieceMediaStore().hasAny('p1'), isFalse);
    });

    test('add appends, and replaces an entry with the same id', () async {
      useStore({});
      final store = PieceMediaStore();
      await store.add('p1', recording('a'));
      await store.add('p1', recording('b'));
      expect((await store.load('p1')).map((m) => m.id), ['a', 'b']);

      await store.add('p1', recording('a').copyWith(label: 'Take one'));
      final media = await store.load('p1');
      // Replaced in place, not duplicated — and moved to the end, which is the
      // order the picker shows.
      expect(media.map((m) => m.id), ['b', 'a']);
      expect(media.last.label, 'Take one');
    });

    test('update replaces in place, keeping the order the picker shows',
        () async {
      useStore({});
      final store = PieceMediaStore();
      await store.add('p1', recording('a'));
      await store.add('p1', recording('b'));
      await store.add('p1', recording('c'));

      await store.update(
          'p1', recording('a').withContentWindow(startSeconds: 3.0));

      final media = await store.load('p1');
      // Unlike add, which moves a re-added medium to the end. Editing a
      // medium's window must not reshuffle the menu under the user.
      expect(media.map((m) => m.id), ['a', 'b', 'c']);
      expect(media.first.contentStartSeconds, 3.0);
    });

    test('update is a no-op for a medium this piece has not stored', () async {
      useStore({});
      final store = PieceMediaStore();
      await store.add('p1', recording('a'));

      // Bundled tracks and the synthesized score are derived, not stored.
      await store.update('p1', recording('bundled_mix'));
      expect((await store.load('p1')).map((m) => m.id), ['a']);
    });

    test('remove takes exactly one medium out', () async {
      useStore({});
      final store = PieceMediaStore();
      await store.add('p1', recording('a'));
      await store.add('p1', recording('b'));

      await store.remove('p1', 'a');
      expect((await store.load('p1')).map((m) => m.id), ['b']);
    });

    test('pieces do not see each other', () async {
      useStore({});
      final store = PieceMediaStore();
      await store.add('p1', recording('a'));
      expect(await store.load('p2'), isEmpty);
    });

    test('one unparseable entry costs its own medium, not the list', () async {
      useStore({
        'pieceMedia.p1': '['
            '{"id":"good","label":"Demo","kind":"recorded",'
            '"alignmentKey":"media:p1:good","avOffsetMs":0},'
            '{"label":"no id here"}]'
      });
      final media = await PieceMediaStore().load('p1');
      expect(media.map((m) => m.id), ['good']);
    });

    test('unparseable stored data reads as no user media', () async {
      useStore({'pieceMedia.p1': 'not json'});
      expect(await PieceMediaStore().load('p1'), isEmpty);
    });

    test('generated ids are unique across calls at different instants', () {
      final first = PieceMediaStore.newMediaId(
          'demo', DateTime.fromMillisecondsSinceEpoch(1000));
      final second = PieceMediaStore.newMediaId(
          'demo', DateTime.fromMillisecondsSinceEpoch(1001));
      expect(first, isNot(second));
      // Usable as a folder name.
      expect(first, matches(RegExp(r'^[A-Za-z0-9_]+$')));
    });
  });

  group('MediaAlignmentStore', () {
    const anchors = [
      ScoreAudioAnchor(0, 0.5),
      ScoreAudioAnchor(1000, 1.6),
      ScoreAudioAnchor(2000, 2.9),
    ];

    test('round-trips anchors, tempo and the uncertainty flag', () async {
      useStore({});
      final store = MediaAlignmentStore();
      await store.save(
        'media:p1:demo',
        const MediaAlignment(
            anchors: anchors, generationBpm: 90, hasCompressedAnchors: true),
      );

      final loaded = await store.load('media:p1:demo');
      expect(loaded, isNotNull);
      expect(loaded!.generationBpm, 90);
      expect(loaded.hasCompressedAnchors, isTrue);
      expect(loaded.anchors, hasLength(3));
      expect(loaded.anchors[1].scoreMs, 1000);
      expect(loaded.anchors[1].audioSec, 1.6);
      expect(await store.isAligned('media:p1:demo'), isTrue);
    });

    test('a piece\'s three bundled mixes share one cached alignment', () async {
      useStore({});
      final store = MediaAlignmentStore();
      // What MediaCatalog gives all three variants.
      await store.save('bundled:lightly_row',
          const MediaAlignment(anchors: anchors, generationBpm: 120));

      expect(await store.isAligned('bundled:lightly_row'), isTrue);
      expect((await store.load('bundled:lightly_row'))!.generationBpm, 120);
    });

    test('fewer than two anchors is not a usable alignment', () async {
      useStore({
        'mediaAlignment.k': '{"generationBpm":100,"hasCompressedAnchors":false,'
            '"anchors":[{"scoreMs":0.0,"audioSec":0.0}]}'
      });
      expect(await MediaAlignmentStore().load('k'), isNull);
    });

    test('unparseable saved data reads as never aligned', () async {
      useStore({'mediaAlignment.k': 'not json'});
      expect(await MediaAlignmentStore().load('k'), isNull);
    });

    test('entries cached before hasCompressedAnchors existed default to false',
        () async {
      useStore({
        'mediaAlignment.k': '{"generationBpm":100,"anchors":['
            '{"scoreMs":0.0,"audioSec":0.0},{"scoreMs":1000.0,"audioSec":1.0}]}'
      });
      final loaded = await MediaAlignmentStore().load('k');
      expect(loaded!.hasCompressedAnchors, isFalse);
    });

    test('clear removes it', () async {
      useStore({});
      final store = MediaAlignmentStore();
      await store.save('k',
          const MediaAlignment(anchors: anchors, generationBpm: 100));
      await store.clear('k');
      expect(await store.load('k'), isNull);
      expect(await store.isAligned('k'), isFalse);
    });
  });
}
