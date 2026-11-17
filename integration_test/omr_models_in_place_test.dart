// Checks that the OMR models open from where the app bundle keeps them, not
// from a copy in Library/Caches (bundled_asset_path_io.dart), and that
// recognition still runs that way. Run on a simulator, with any saved crop:
//
//   flutter test integration_test/omr_models_in_place_test.dart -d dev-iphone-se \
//     --dart-define=OMR_PAGE=$PWD/../violin_dev_library/scan_sources/<id>/page_1_crop.jpg
//
// Without OMR_PAGE it checks the paths only. The page is decoded before
// recognition, so a JPEG crop is as good as the PNG the scan pipeline hands in.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homr_flutter/homr_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:violin_practice_companion/services/bundled_asset_path.dart';

const _page = String.fromEnvironment('OMR_PAGE');
const _dir = 'assets/engine/omr_models';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('OMR models load by path and recognise a page', (tester) async {
    await tester.runAsync(() async {
      for (final name in [
        OmrModels.segnetFile,
        OmrModels.encoderFile,
        OmrModels.decoderFile,
      ]) {
        final path = await bundledAssetPath('$_dir/$name');
        expect(path, isNotNull, reason: name);
        expect(File(path!).lengthSync(), greaterThan(1000000), reason: path);
      }
      if (_page.isEmpty) return;

      final omr = OmrOrchestrator(
          models: OmrModels.inAssetDir(_dir, resolvePath: bundledAssetPath));
      final decoded = img.decodeImage(File(_page).readAsBytesSync())!;
      final xml = await omr.recognise(img.encodePng(decoded));
      expect(xml, contains('<note'));

      // The plugin's own route would have left the models here.
      final cache = await getTemporaryDirectory();
      final copies = cache
          .listSync()
          .where((e) => e.path.endsWith('.onnx'))
          .map((e) => e.path)
          .toList();
      expect(copies, isEmpty);
    });
  });
}
