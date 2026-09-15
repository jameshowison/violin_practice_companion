import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/services/audio_score_auto_aligner.dart';
import 'package:violin_practice_companion/services/teacher_recording_store.dart';

void main() {
  TeacherRecordingStore freshStore(Map<String, Object> initial) {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(initial);
    // A new store each time: SharedPreferences caches its instance, and the
    // mock values are only picked up on a fresh getInstance().
    return TeacherRecordingStore();
  }

  const anchors = [
    ScoreAudioAnchor(0, 0.5),
    ScoreAudioAnchor(1000, 1.6),
    ScoreAudioAnchor(2000, 2.9),
  ];

  test('absent means no recording', () async {
    final store = freshStore({});
    expect(await store.load('p1'), isNull);
    expect(await store.has('p1'), isFalse);
  });

  test('round-trips every field', () async {
    final store = freshStore({});
    await store.save(
      'p1',
      videoPath: '/docs/teacher_recordings/p1/video.mp4',
      audioPath: '/docs/teacher_recordings/p1/audio.wav',
      avOffsetMs: 37,
      anchors: anchors,
      generationBpm: 90,
      hasCompressedAnchors: true,
    );

    final loaded = await store.load('p1');
    expect(loaded, isNotNull);
    expect(loaded!.videoPath, '/docs/teacher_recordings/p1/video.mp4');
    expect(loaded.audioPath, '/docs/teacher_recordings/p1/audio.wav');
    expect(loaded.avOffsetMs, 37);
    expect(loaded.generationBpm, 90);
    expect(loaded.hasCompressedAnchors, isTrue);
    expect(loaded.anchors.length, 3);
    expect(loaded.anchors[1].scoreMs, 1000);
    expect(loaded.anchors[1].audioSec, 1.6);
    expect(await store.has('p1'), isTrue);
  });

  test('pieces do not see each other', () async {
    final store = freshStore({});
    await store.save('p1',
        videoPath: 'v1',
        audioPath: 'a1',
        avOffsetMs: 0,
        anchors: anchors,
        generationBpm: 100,
        hasCompressedAnchors: false);

    expect(await store.load('p2'), isNull);
    expect(await store.has('p2'), isFalse);
  });

  test('re-saving overwrites the previous recording', () async {
    final store = freshStore({});
    await store.save('p1',
        videoPath: 'v1',
        audioPath: 'a1',
        avOffsetMs: 10,
        anchors: anchors,
        generationBpm: 100,
        hasCompressedAnchors: false);
    await store.save('p1',
        videoPath: 'v2',
        audioPath: 'a2',
        avOffsetMs: -5,
        anchors: anchors,
        generationBpm: 120,
        hasCompressedAnchors: true);

    final loaded = await store.load('p1');
    expect(loaded!.videoPath, 'v2');
    expect(loaded.avOffsetMs, -5);
    expect(loaded.generationBpm, 120);
    expect(loaded.hasCompressedAnchors, isTrue);
  });

  test('clear removes the recording', () async {
    final store = freshStore({});
    await store.save('p1',
        videoPath: 'v1',
        audioPath: 'a1',
        avOffsetMs: 0,
        anchors: anchors,
        generationBpm: 100,
        hasCompressedAnchors: false);

    await store.clear('p1');

    expect(await store.load('p1'), isNull);
    expect(await store.has('p1'), isFalse);
  });

  test('fewer than 2 anchors is treated as no recording', () async {
    final prefs = <String, Object>{
      'teacherRecording.p1': '{'
          '"videoPath":"v1","audioPath":"a1","avOffsetMs":0,'
          '"generationBpm":100,"hasCompressedAnchors":false,'
          '"anchors":[{"scoreMs":0.0,"audioSec":0.0}]}'
    };
    final store = freshStore(prefs);
    expect(await store.load('p1'), isNull);
  });

  test('unparsable saved data is treated as no recording', () async {
    final store = freshStore({'teacherRecording.p1': 'not json'});
    expect(await store.load('p1'), isNull);
  });
}
