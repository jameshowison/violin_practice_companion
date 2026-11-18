import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// The project's home, linked from the Thanks screen and the licence page.
const kSourceRepoUrl =
    'https://github.com/jameshowison/violin_practice_companion';

/// Licences for what the app bundles that no pub package carries a LICENSE
/// for. Flutter's licence page already lists every Dart package (homr_flutter,
/// verovio_flutter, …) from its own LICENSE file; this adds the rest.
///
/// Each entry: the names it covers, and its text under assets/.
const bundledLicenseAssets = <(List<String>, String)>[
  (['homr'], 'assets/engine/licenses/homr.txt'),
  (
    ['OpenSheetMusicDisplay', 'VexFlow', 'JSZip', 'pako'],
    'assets/engine/licenses/opensheetmusicdisplay.txt'
  ),
  (['abcjs'], 'assets/engine/licenses/abcjs.txt'),
  (['GeneralUser GS'], 'assets/engine/licenses/generaluser_gs.txt'),
  // The Playful skin's typeface; SIL OFL 1.1 asks for it to travel with it.
  (['Nunito'], 'assets/engine/fonts/OFL.txt'),
  // The score engraver, its embedded libraries and its music fonts.
  (['Verovio'], 'assets/engine/licenses/verovio.txt'),
  // flutter_midi_pro's Android synth: FluidSynth, GLib and the codecs.
  (
    ['FluidSynth and its Android libraries'],
    'assets/engine/licenses/fluidsynth.txt'
  ),
  (['ONNX Runtime'], 'assets/engine/licenses/onnxruntime.txt'),
  // The text models that read a scanned page's title.
  (['PaddleOCR', 'RapidOCR'], 'assets/engine/licenses/paddleocr.txt'),
  (['iOS libraries (CocoaPods)'], 'assets/engine/licenses/ios_pods.txt'),
  (['Android libraries'], 'assets/engine/licenses/android_libraries.txt'),
];

/// The GNU GPL version 3, appended to Stringlings' own entry.
const gplLicenseAsset = 'assets/engine/licenses/gpl-3.0.txt';

/// Stringlings' own entry, at the top of its package list.
const _ownLicense = '''
Stringlings is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

It is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
A PARTICULAR PURPOSE. See the GNU General Public License for more details.

The source code is at
$kSourceRepoUrl

The full text of the GNU General Public License, version 3, follows.
''';

void registerBundledLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['Stringlings'],
        '$_ownLicense\n${await rootBundle.loadString(gplLicenseAsset)}');
    for (final (packages, asset) in bundledLicenseAssets) {
      yield LicenseEntryWithLineBreaks(
          packages, await rootBundle.loadString(asset));
    }
  });
}
