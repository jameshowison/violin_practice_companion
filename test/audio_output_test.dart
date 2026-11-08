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
}
