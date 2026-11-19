import 'package:flutter_test/flutter_test.dart';
import 'package:violin_practice_companion/services/media_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('no native video transport (Android) → null, so the service keeps '
      'the sound-only player and the overlay its own video', () async {
    expect(await NativeTransport.open('/nonexistent/video.mp4'), isNull);
  });

  test('a portrait capture turned 90° shows tall', () {
    const landscape = VideoPicture(1, 1920, 1080, 0);
    const portrait = VideoPicture(1, 1920, 1080, 90);
    expect(landscape.aspectRatio, closeTo(16 / 9, 1e-9));
    expect(portrait.aspectRatio, closeTo(9 / 16, 1e-9));
    expect(const VideoPicture(1, 0, 0, 0).aspectRatio, 16 / 9);
  });
}
