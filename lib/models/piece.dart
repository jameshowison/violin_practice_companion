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

  Piece copyWith({List<Section>? sections}) => Piece(
        id: id,
        title: title,
        musicXmlAssetPath: musicXmlAssetPath,
        musicXmlFilePath: musicXmlFilePath,
        sectionsAssetPath: sectionsAssetPath,
        sections: sections ?? this.sections,
      );
}
