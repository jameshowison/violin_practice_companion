import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
