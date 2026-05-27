import 'section.dart';

class Piece {
  final String id;
  final String title;
  final String musicXmlAssetPath;
  final String sectionsAssetPath;
  final List<Section> sections;

  const Piece({
    required this.id,
    required this.title,
    required this.musicXmlAssetPath,
    required this.sectionsAssetPath,
    required this.sections,
  });

  Piece copyWith({List<Section>? sections}) => Piece(
        id: id,
        title: title,
        musicXmlAssetPath: musicXmlAssetPath,
        sectionsAssetPath: sectionsAssetPath,
        sections: sections ?? this.sections,
      );
}
