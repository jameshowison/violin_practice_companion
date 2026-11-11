import 'dart:typed_data';

/// Reads a scanned piece's title off the page it was scanned from.
abstract class TitleRecognizerBase {
  /// The title printed over the music the user cropped: [original] is the page
  /// as acquired, [cropped] the user's crop of it (see `title_region.dart`
  /// for where it looks and how it chooses). Null if no title was found or
  /// this platform cannot read text; never throws.
  Future<String?> recognise({required Uint8List original, required Uint8List cropped});
}
