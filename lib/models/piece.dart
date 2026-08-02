import 'section.dart';

class Piece {
  final String id;
  final String title;
  final String? musicXmlAssetPath;
  final String? musicXmlFilePath;
  final String? sectionsAssetPath;
  final List<Section> sections;

  const Piece({
    required this.id,
    required this.title,
    this.musicXmlAssetPath,
    this.musicXmlFilePath,
    this.sectionsAssetPath,
    required this.sections,
  }) : assert(
          (musicXmlAssetPath == null) != (musicXmlFilePath == null),
          'Exactly one of musicXmlAssetPath or musicXmlFilePath must be set',
        );

  Piece copyWith({String? title, List<Section>? sections}) => Piece(
        id: id,
        title: title ?? this.title,
        musicXmlAssetPath: musicXmlAssetPath,
        musicXmlFilePath: musicXmlFilePath,
        sectionsAssetPath: sectionsAssetPath,
        sections: sections ?? this.sections,
      );

  /// This piece re-pointed at a writable copy at [filePath] — what happens the
  /// first time a bundled fixture is edited.
  ///
  /// A separate method rather than a `copyWith` parameter because the
  /// constructor asserts exactly one of the two paths is set, so "set the file
  /// path" must ALSO mean "drop the asset path". A `?? this.x` parameter has no
  /// way to say null-on-purpose, which is why callers used to hand-build a
  /// `Piece` here and could silently break the invariant.
  Piece backedByFile(String filePath) => Piece(
        id: id,
        title: title,
        musicXmlFilePath: filePath,
        sectionsAssetPath: sectionsAssetPath,
        sections: sections,
      );

  // Deliberately NO == / hashCode. A Piece carries no content hash, so after an
  // in-place MusicXML edit a "new" Piece would be value-equal to the old one,
  // `selectedPieceProvider` would not notify, and the staff would not
  // re-engrave. Identity comparison is load-bearing here.
}
