import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violin_practice_companion/services/audio_output.dart';

void main() {
  test('latency is the port latency plus one render buffer', () {
    final r = AudioOutputRoute.fromMap({
      'portName': 'JBL Flip',
      'portType': 'BluetoothA2DPOutput',
      'uid': 'aa:bb',
      'outputLatency': 0.18,
      'ioBufferDuration': 0.0116,
    });
    expect(r.latencySeconds, closeTo(0.1916, 1e-9));
    expect(r.portType, 'BluetoothA2DPOutput');
  });

  test('missing, negative and absurd values cannot move the cursor far', () {
    expect(AudioOutputRoute.fromMap({}).latencySeconds, 0);
    expect(
        AudioOutputRoute.fromMap({'outputLatency': -1, 'ioBufferDuration': 0.01})
            .latencySeconds,
        closeTo(0.01, 1e-9));
    expect(AudioOutputRoute.fromMap({'outputLatency': 60.0}).latencySeconds,
        AudioOutputRoute.maxLatencySeconds);
  });

  test('without a native side there is no compensation', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AudioOutput.ensureStarted();
    expect(AudioOutput.latencySeconds, 0);
  });

  group('output picker', () {
    const channel = MethodChannel('violin_practice_companion/audio_route');
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      AudioOutput.debugSetRoute(null);
    });

    test('is not offered until a native side has reported a route', () {
      AudioOutput.debugSetRoute(null);
      expect(AudioOutput.canPick, isFalse);
      AudioOutput.debugSetRoute(AudioOutputRoute.fromMap({'portType': 'Speaker'}));
      expect(AudioOutput.canPick, isTrue);
    });

    test('showPicker is false without a native side', () async {
      expect(await AudioOutput.showPicker(), isFalse);
    });

    test('showPicker reports what the native side did', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'showPicker');
        return true;
      });
      expect(await AudioOutput.showPicker(), isTrue);
    });
  });

  group('per-speaker measured delay', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    AudioOutputRoute bt(String uid) => AudioOutputRoute.fromMap({
          'portName': 'Speaker $uid',
          'portType': 'BluetoothA2DPOutput',
          'uid': uid,
          'outputLatency': 0.15,
          'ioBufferDuration': 0.01,
        });

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AudioOutput.calibratedDelaysMs.value = const {};
    });
    tearDown(() => AudioOutput.debugSetRoute(null));

    test('is kept by speaker name and type, not by iOS\'s port id', () async {
      AudioOutput.debugSetRoute(bt('jbl'));
      await AudioOutput.setCalibratedDelayMs(AudioSyncSource.recording, 500);
      AudioOutput.debugSetRoute(AudioOutputRoute.fromMap({
        'portName': 'Speaker jbl',
        'portType': 'BluetoothA2DPOutput',
        'uid': 'a-new-id-after-reconnecting',
      }));
      expect(AudioOutput.calibratedDelayMs(AudioSyncSource.recording), 500);
    });

    test('a calibration is stored for the speaker it started on', () async {
      final roam = bt('roam');
      AudioOutput.debugSetRoute(bt('passing'));
      await AudioOutput.setCalibratedDelayMs(AudioSyncSource.recording, 530,
          on: roam);
      expect(AudioOutput.calibratedDelayMs(AudioSyncSource.recording), isNull);
      AudioOutput.debugSetRoute(roam);
      expect(AudioOutput.calibratedDelayMs(AudioSyncSource.recording), 530);
    });

    test('replaces the iOS estimate, for that speaker and player only',
        () async {
      AudioOutput.debugSetRoute(bt('jbl'));
      expect(AudioOutput.heardDelaySeconds(AudioSyncSource.recording),
          closeTo(0.16, 1e-9));
      await AudioOutput.setCalibratedDelayMs(AudioSyncSource.recording, 70);
      expect(AudioOutput.heardDelaySeconds(AudioSyncSource.recording),
          closeTo(0.07, 1e-9));
      // Not shared: the synth's delay differs from AVPlayer's.
      expect(AudioOutput.heardDelaySeconds(AudioSyncSource.score),
          closeTo(0.16, 1e-9));

      AudioOutput.debugSetRoute(bt('car'));
      expect(AudioOutput.calibratedDelayMs(AudioSyncSource.recording), isNull);
      AudioOutput.debugSetRoute(bt('jbl'));
      expect(AudioOutput.calibratedDelayMs(AudioSyncSource.recording), 70);
    });

    test('is saved, and forgetting it removes it', () async {
      AudioOutput.debugSetRoute(bt('jbl'));
      await AudioOutput.setCalibratedDelayMs(AudioSyncSource.recording, 90);
      final prefs = await SharedPreferences.getInstance();
      final key = AudioOutput.syncDelayKey(
          AudioSyncSource.recording, 'BluetoothA2DPOutput|Speaker jbl');
      expect(prefs.getInt(key), 90);
      await AudioOutput.setCalibratedDelayMs(AudioSyncSource.recording, null);
      expect(prefs.containsKey(key), isFalse);
      expect(AudioOutput.calibratedDelayMs(AudioSyncSource.recording), isNull);
    });

    test('a recording may be measured negative; the score never goes below 0',
        () async {
      AudioOutput.debugSetRoute(bt('jbl'));
      await AudioOutput.setCalibratedDelayMs(AudioSyncSource.recording, -40);
      await AudioOutput.setCalibratedDelayMs(AudioSyncSource.score, -40);
      expect(AudioOutput.heardDelaySeconds(AudioSyncSource.recording),
          closeTo(-0.04, 1e-9));
      expect(AudioOutput.heardDelaySeconds(AudioSyncSource.score), 0);
    });

    test('no route: nothing stored, no delay', () async {
      await AudioOutput.setCalibratedDelayMs(AudioSyncSource.score, 200);
      expect(AudioOutput.heardDelaySeconds(AudioSyncSource.score), 0);
    });
  });
}
